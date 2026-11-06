import { encodePacket } from 'engine.io-parser';
import { Encoder } from 'socket.io-parser';
import { writeFileSync } from 'node:fs';
const encoder = new Encoder();
const packets = [
  { type: 0 }, { type: 0, data: { sid: 'socket-id' } }, { type: 1 },
  { type: 2, data: ['submitOp', 'client', [[{ contents: '\ud800', sequenceNumber: 1 }]]] },
  { type: 2, id: 0, data: ['ping'] }, { type: 3, id: 0, data: [] },
  { type: 3, id: 42, data: [{ '9': 9, '2': 2, z: 1e-7, a: '💧' }] },
  { type: 4, data: { message: 'denied', data: { code: 403 } } },
];
const frames = [];
for (const packet of packets) {
  for (const data of encoder.encode({ nsp: '/', ...packet })) {
    await new Promise(resolve => encodePacket({ type: 'message', data }, false, encoded => { frames.push(encoded); resolve(); }));
  }
}
for (const packet of [
  { type: 'open', data: JSON.stringify({ sid: 'engine-id', upgrades: [], pingInterval: 100, pingTimeout: 200 }) },
  { type: 'ping' }, { type: 'ping', data: 'probe' }, { type: 'pong', data: 'probe' }, { type: 'close' }, { type: 'noop' },
]) await new Promise(resolve => encodePacket(packet, false, encoded => { frames.push(encoded); resolve(); }));
writeFileSync(new URL('../../Tests/FluidSocketIOTests/Fixtures/packets.json', import.meta.url), JSON.stringify(frames, null, 2) + '\n');
