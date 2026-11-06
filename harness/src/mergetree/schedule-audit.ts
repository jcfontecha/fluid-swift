/** Checks the service/runtime preconditions independently of merge-tree. */
import assert from 'node:assert/strict';
import { isDeepStrictEqual } from 'node:util';
import { messageSchema } from './protocol.js';
export class ScheduleAudit {
    private readonly cursors = new Map<string, number>();
    private readonly submitted = new Map<string, {
        contents: unknown;
        ref: number;
    }[]>();
    private readonly log = new Map<number, unknown>();
    private readonly minima = new Map<string, number>();
    private serviceMin = 0;
    private readonly serviceCounts = new Map<string, number>();
    private readonly serviceRefs = new Map<string, number>();
    create(client: string) {
        this.cursors.set(client, 0);
        this.submitted.set(client, []);
        this.minima.set(client, 0);
        this.serviceRefs.set(client, 0);
    }
    edit(client: string, contents: unknown) {
        if (contents === null)
            return;
        const pending = this.submitted.get(client);
        assert(pending);
        pending.push({ contents, ref: this.cursors.get(client) ?? 0 });
    }
    process(client: string, value: unknown) {
        const m = messageSchema.parse(value);
        assert.equal(m.sequenceNumber, (this.cursors.get(client) ?? 0) + 1, 'ordered delivery');
        const local = this.submitted.get(m.clientId)?.[m.clientSequenceNumber - 1];
        assert(local, 'op must have been submitted');
        assert.equal(m.referenceSequenceNumber, local.ref, 'refSeq is local currentSeq at submission');
        assert(isDeepStrictEqual(m.contents, local.contents), 'ack and wire op match submitted op');
        assert(m.minimumSequenceNumber <= m.referenceSequenceNumber, 'refSeq remains in service window');
        assert(m.minimumSequenceNumber >= (this.minima.get(client) ?? 0), 'minSeq is monotonic');
        const known = this.log.get(m.sequenceNumber);
        if (known !== undefined) {
            assert(isDeepStrictEqual(known, m), 'all recipients get the same envelope');
        }
        else {
            assert.equal(m.sequenceNumber, this.log.size + 1, 'contiguous service sequence');
            assert(m.referenceSequenceNumber >= this.serviceMin, 'Deli rejects stale refSeq');
            assert(m.referenceSequenceNumber < m.sequenceNumber, 'refSeq precedes sequence');
            assert.equal(m.clientSequenceNumber, (this.serviceCounts.get(m.clientId) ?? 0) + 1, 'FIFO client submission and ack');
            this.serviceCounts.set(m.clientId, m.clientSequenceNumber);
            this.serviceRefs.set(m.clientId, m.referenceSequenceNumber);
            assert(m.minimumSequenceNumber <= Math.min(...this.serviceRefs.values()), 'service minimum cannot pass a lagging client');
            this.serviceMin = m.minimumSequenceNumber;
            this.log.set(m.sequenceNumber, m);
        }
        this.cursors.set(client, m.sequenceNumber);
        this.minima.set(client, m.minimumSequenceNumber);
    }
    minSeq(client: string, seq: number) {
        assert(seq >= (this.minima.get(client) ?? 0));
        assert([...this.cursors.values()].every(cursor => cursor >= seq), 'checkpoint delivered to all clients');
        const sequencedCount = [...this.log.values()].map(m => messageSchema.parse(m)).filter(m => m.clientId === client).length;
        assert.equal(sequencedCount, this.submitted.get(client)?.length, 'checkpoint has no pending local ops');
        this.minima.set(client, seq);
        this.serviceMin = Math.max(this.serviceMin, seq);
        // The harness checkpoint models all clients advertising this ref after draining.
        for (const id of this.serviceRefs.keys())
            this.serviceRefs.set(id, seq);
    }
}
