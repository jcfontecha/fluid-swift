import assert from 'node:assert/strict';
import { spawn, execFileSync } from 'node:child_process';
import { createServer, connect, type Socket } from 'node:net';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { resolve, join } from 'node:path';
import { createInterface } from 'node:readline';
import { once } from 'node:events';
import { OdspClient } from '@fluidframework/odsp-client/beta';
import { TinyliciousClient } from '@fluidframework/tinylicious-client';
import { isInternalFluidContainer } from '@fluidframework/fluid-static/internal';
import { SharedMap } from '@fluidframework/map/internal';
import { z } from 'zod';
import { OdspLocalService } from '../odsp-service/server.js';
const schema = { initialObjects: { map: SharedMap } };
const viewSchema = z.object({ state: z.record(z.string(), z.unknown()), connected: z.boolean(), dirty: z.boolean(), clientId: z.string().nullable(), events: z.array(z.string()) });
const sleep = (ms: number) => new Promise<void>(resolve => setTimeout(resolve, ms));
async function until(condition: () => Promise<boolean> | boolean) {
    const deadline = Date.now() + 60000;
    while (Date.now() < deadline) {
        if (await condition())
            return;
        await sleep(10);
    }
    throw new Error('live recovery timed out');
}
execFileSync('swift', ['build', '--scratch-path', '.build/reconnect', '--product', 'FluidReconnectPeer'], { cwd: '..', stdio: 'inherit' });
for (const kind of ['tinylicious', 'odsp'] as const) {
    const temporary = await mkdtemp(join(tmpdir(), 'reconnect-live-'));
    const sockets = new Set<Socket>();
    const tiny = kind === 'tinylicious' ? spawn(process.execPath, [resolve('node_modules/tinylicious/dist/index.js')], {
        cwd: temporary, env: { ...process.env, PORT: '7082', storage: join(temporary, 'storage') }, stdio: 'ignore',
    }) : undefined;
    const proxy = kind === 'tinylicious' ? createServer(socket => {
        const upstream = connect(7082, '127.0.0.1');
        sockets.add(socket);
        socket.pipe(upstream).pipe(socket);
        socket.on('error', () => upstream.destroy());
        upstream.on('error', () => socket.destroy());
        socket.on('close', () => { sockets.delete(socket); upstream.destroy(); });
    }) : undefined;
    if (proxy)
        await new Promise<void>(resolve => proxy.listen(7081, resolve));
    const odsp = kind === 'odsp' ? await OdspLocalService.start(7093) : undefined;
    const peer = spawn('.build/reconnect/debug/FluidReconnectPeer', [], { cwd: '..', stdio: ['pipe', 'pipe', 'inherit'] });
    const lines = createInterface({ input: peer.stdout })[Symbol.asyncIterator]();
    async function rpc(request: Record<string, unknown>) {
        peer.stdin.write(JSON.stringify(request) + '\n');
        const line = await lines.next();
        assert(!line.done, 'peer exited');
        return viewSchema.parse(JSON.parse(line.value));
    }
    let dispose: (() => void) | undefined;
    try {
        if (tiny)
            await until(async () => { try {
                return (await fetch('http://localhost:7081')).ok;
            }
            catch {
                return false;
            } });
        const client = kind === 'odsp' ? new OdspClient({ connection: {
                siteUrl: 'http://localhost:7093', driveId: 'b!bG9jYWwtb2RzcA', filePath: '', tokenProvider: {
                    fetchStorageToken: async () => ({ token: 'storage:ts' }), fetchWebsocketToken: async () => ({ token: 'push:ts' }),
                },
            } }) : new TinyliciousClient({ connection: { port: 7081 } });
        const { container } = await client.createContainer(schema, '2.0.0');
        dispose = () => container.dispose();
        const id = await container.attach();
        assert(isInternalFluidContainer(container));
        const inner = container.container;
        const tsEvents: string[] = [];
        inner.on('connected', () => tsEvents.push('connected'));
        inner.on('disconnected', () => tsEvents.push('disconnected'));
        await until(() => inner.connectionState === 2);
        await rpc({ method: 'open', kind, id, port: kind === 'odsp' ? 7093 : 7081 });
        await until(async () => (await rpc({ method: 'view' })).connected);
        for (let round = 0; round < 3; round++) {
            const previous = await rpc({ method: 'view' });
            container.initialObjects.map.set(`ts-${round}`, round);
            await rpc({ method: 'edit', key: `swift-${round}`, value: round });
            if (odsp) {
                // Do not reproduce the TS 3.11.0 multiplexed-handshake crash. The service's
                // fault method refuses injection until that socket has no handshake in flight.
                for (const clientId of [inner.clientId, previous.clientId]) {
                    assert(clientId);
                    await until(() => odsp.push.serverDisconnect(clientId, 500));
                }
            }
            else {
                for (const socket of sockets)
                    socket.destroy();
            }
            await rpc({ method: 'edit', key: `offline-swift-${round}`, value: round });
            container.initialObjects.map.set(`offline-ts-${round}`, round);
            await until(async () => {
                const next = await rpc({ method: 'view' });
                return next.connected && next.clientId !== previous.clientId && !next.dirty && inner.connectionState === 2 && !inner.isDirty
                    && JSON.stringify(Object.entries(next.state).sort()) === JSON.stringify([...container.initialObjects.map.entries()].sort());
            });
        }
        const result = await rpc({ method: 'view' });
        assert(result.events.filter(event => event === 'disconnected').length >= 3);
        assert(tsEvents.filter(event => event === 'disconnected').length >= 3);
        assert.equal(Object.keys(result.state).length, 12);
        console.log(`${kind}: TS + Swift recovered from 3 service socket drops; 12 edits converged without connect()`);
    }
    finally {
        dispose?.();
        peer.kill();
        for (const socket of sockets)
            socket.destroy();
        if (proxy)
            await new Promise<void>(resolve => proxy.close(() => resolve()));
        await odsp?.close();
        if (tiny) {
            const exit = once(tiny, 'exit');
            tiny.kill();
            await exit;
        }
        await rm(temporary, { recursive: true, force: true });
    }
}
process.exit(0);
