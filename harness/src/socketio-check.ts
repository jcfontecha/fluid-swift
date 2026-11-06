import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { createServer } from 'node:http';
import { createServer as createNetServer } from 'node:net';
import { mkdtemp, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { resolve, join } from 'node:path';
import { once } from 'node:events';
import { Server } from 'socket.io';
import { InsecureTokenProvider } from '@fluidframework/test-runtime-utils/internal';

const root = resolve(import.meta.dirname, '../..');
const temporary = await mkdtemp(join(tmpdir(), 'fluid-socketio-'));
const processes = [];
let logs = '';
let failure;
let clientClosed = false;
const http = createServer();
const io = new Server(http, { path: '/fluid-test', transports: ['websocket'], pingInterval: 100, pingTimeout: 500 });
io.use((socket, next) => next(socket.handshake.query.reject ? new Error('denied') : undefined));
let connections = 0;
io.on('connection', socket => {
  connections++;
  if (connections === 1) {
    try {
      assert.equal(socket.handshake.query.tenantId, 'tenant & 💧');
      assert.equal(socket.handshake.query.documentId, 'doc/1');
    } catch (error) { failure = error; }
  }
  let pongs = 0;
  socket.conn.on('packet', packet => {
    if (packet.type === 'pong' && ++pongs === 3) socket.emit('heartbeat_count', pongs);
  });
  socket.emit('server_event', { ordered: 1 });
  for (let i = 0; i < 20; i++) socket.emit('ordered', i);
  socket.emit('needs_ack', 'reply', (response: unknown) => {
    try { assert.equal(response, 'reply'); socket.emit('server_ack_ok'); }
    catch (error) { failure = error; }
  });
  socket.on('plain', value => {
    try { assert.deepEqual(value, { hello: '💧', surrogate: '\ud800' }); socket.emit('observed'); }
    catch (error) { failure = error; }
  });
  socket.on('with_ack', (value, ack) => ack(value, 'ok'));
  socket.on('disconnect_me', () => socket.disconnect(true));
  socket.on('disconnect', reason => {
    if (connections === 2 && reason === 'client namespace disconnect') clientClosed = true;
  });
});

async function run(command: string, args: string[], options: import("node:child_process").SpawnOptions = {}) {
  const child = spawn(command, args, { cwd: root, stdio: 'inherit', ...options });
  processes.push(child);
  const [code, signal] = await once(child, 'exit');
  assert.equal(code, 0, `${command} exited ${code} (${signal})`);
}
try {
  await new Promise<void>((resolve, reject) => http.once('error', reject).listen(7172, '127.0.0.1', resolve));
  const portProbe = createNetServer();
  await new Promise<void>((resolve, reject) => portProbe.once('error', reject).listen(7072, '127.0.0.1', resolve));
  await new Promise<void>(resolve => portProbe.close(() => resolve()));
  const tiny = spawn(process.execPath, [resolve(root, 'harness/node_modules/tinylicious/dist/index.js')], {
    cwd: temporary, env: { ...process.env, PORT: '7072', storage: join(temporary, 'storage') }, stdio: ['ignore', 'pipe', 'pipe'],
  });
  processes.push(tiny);
  tiny.stdout.on('data', data => { logs += data; });
  tiny.stderr.on('data', data => { logs += data; });
  let ready = false;
  for (let i = 0; i < 150; i++) {
    if (tiny.exitCode !== null) throw new Error(`tinylicious exited: ${logs}`);
    try { const response = await fetch('http://127.0.0.1:7072'); if (response.ok) { ready = true; break; } } catch {}
    await new Promise(resolve => setTimeout(resolve, 100));
  }
  assert(ready, `tinylicious did not start: ${logs}`);
  const id = 'swift-socketio-' + crypto.randomUUID();
  const created = await fetch('http://127.0.0.1:7072/documents/tinylicious', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ id, summary: { type: 1, tree: {} }, sequenceNumber: 0, values: [] }) });
  assert.equal(created.status, 201, await created.text());
  const token = (await new InsecureTokenProvider('12345', { id: 'swift-user', name: 'Swift Socket.IO' }).fetchOrdererToken('tinylicious', id)).jwt;
  const message = {
    client: { mode: 'write', details: { capabilities: { interactive: true }, environment: 'socketio-check', type: 'interactive' }, permission: [], scopes: [], user: { id: 'swift-user' } },
    id, mode: 'write', tenantId: 'tinylicious', token,
    versions: ['^0.4.0', '^0.3.0', '^0.2.0', '^0.1.0'],
    relayUserAgent: 'socketio-check; driverVersion:3.11.0', supportedFeatures: { submit_signals_v2: true },
  };
  const messagePath = join(temporary, 'connect.json');
  await writeFile(messagePath, JSON.stringify(message));
  await run('swift', ['build', '--scratch-path', '.build/c2', '--target', 'FluidSocketIOCheck']);
  await run('swift', ['run', '--scratch-path', '.build/c2', '--skip-build', 'FluidSocketIOCheck', messagePath], { timeout: 45000 });
  if (failure) throw failure;
  assert(clientClosed, 'server did not observe client namespace disconnect');
  console.log('Server verified query, events, ACKs, >=3 Engine.IO pongs and client close.');
} catch (error) {
  console.error(logs.slice(-12000));
  throw error;
} finally {
  for (const child of processes) {
    if (!child.pid || child.exitCode !== null || child.signalCode !== null) continue;
    const exited = once(child, 'exit');
    child.kill('SIGTERM');
    const force = setTimeout(() => child.kill('SIGKILL'), 3000);
    await exited;
    clearTimeout(force);
  }
  await new Promise(resolve => io.close(resolve));
  await rm(temporary, { recursive: true, force: true });
}
