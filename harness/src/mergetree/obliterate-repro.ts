import assert from 'node:assert/strict';
import { ScheduleAudit } from './schedule-audit.js';
import { Peer } from './transport.js';
import { stateSchema, type Edit } from './protocol.js';
const audit = new ScheduleAudit();
const peer = new Peer('ts', []);
const ids = ['A', 'B', 'C'];
const counts = new Map<string, number>();
const cursors = new Map<string, number>();
const messages: Record<string, unknown>[] = [];
async function edit(client: string, edit: Edit) {
    const contents = await peer.call('edit', { client, edit });
    audit.edit(client, contents);
    const count = (counts.get(client) ?? 0) + 1;
    counts.set(client, count);
    messages.push({ clientId: client, clientSequenceNumber: count, referenceSequenceNumber: cursors.get(client) ?? 0, sequenceNumber: messages.length + 1, minimumSequenceNumber: 0, type: 'op', contents });
}
async function deliver(client: string, end: number) {
    for (let i = cursors.get(client) ?? 0; i < end; i++) {
        audit.process(client, messages[i]);
        await peer.call('process', { client, message: messages[i] });
        cursors.set(client, i + 1);
    }
}
try {
    for (const client of ids) {
        audit.create(client);
        await peer.call('create', { client, obliterate: true });
    }
    await edit('C', { kind: 'insert', pos: 0, text: 'abcdefghijklm' });
    for (const client of ids)
        await deliver(client, 1);
    await edit('A', { kind: 'insert', pos: 11, text: 'X' });
    await edit('B', { kind: 'insert', pos: 13, text: 'Y' });
    await edit('A', { kind: 'obliterate', start: 10, end: 13 });
    await edit('B', { kind: 'obliterate', start: 8, end: 13 });
    await deliver('B', 2);
    const before = stateSchema.parse(await peer.call('state', { client: 'B' }));
    assert.equal(String.fromCharCode(...before.text), 'abcdefghY');
    await edit('B', { kind: 'remove', start: 6, end: 9 });
    for (const client of ids) {
        await deliver(client, messages.length);
        const s = stateSchema.parse(await peer.call('state', { client }));
        const expected = client === 'B' ? 'abcdef' : 'abcdefY';
        assert.equal(String.fromCharCode(...s.text), expected);
        assert.equal(s.length, expected.length);
        console.log(client, expected, s.length);
    }
}
finally {
    peer.close();
}
