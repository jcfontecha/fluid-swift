import { z } from 'zod';
import { IdCompressor } from '../../node_modules/@fluidframework/id-compressor/lib/idCompressor.js';
import { assertIsSessionId, assertIsStableId } from '../../node_modules/@fluidframework/id-compressor/lib/utilities.js';
import type { OpSpaceCompressedId } from '@fluidframework/id-compressor';
import type { IdCreationRange, SerializedIdCompressorWithOngoingSession } from '@fluidframework/id-compressor/internal';

const range = z.object({
    sessionId: z.string(),
    ids: z.object({ firstGenCount: z.number(), count: z.number(), requestedClusterSize: z.number(), localIdRanges: z.array(z.tuple([z.number(), z.number()])) }).optional()
});
export const command = z.discriminatedUnion('kind', [
    z.object({ kind: z.literal('load'), client: z.number(), serialized: z.string() }),
    z.object({ kind: z.literal('generate'), client: z.number(), count: z.number() }),
    z.object({ kind: z.literal('take'), client: z.number() }),
    z.object({ kind: z.literal('reset'), client: z.number() }),
    z.object({ kind: z.literal('capacity'), client: z.number(), size: z.number() }),
    z.object({ kind: z.literal('finalize'), client: z.number(), range }),
    z.object({ kind: z.literal('query'), client: z.number(), id: z.number(), origin: z.string(), stable: z.string() }),
    z.object({ kind: z.literal('restore'), client: z.number(), local: z.boolean(), newSession: z.string(), version: z.union([z.literal(2), z.literal(3)]) })
]);
export type Command = z.infer<typeof command>;
export const scenarioSchema = z.object({ sessions: z.array(z.string()), version: z.union([z.literal(2), z.literal(3)]), commands: z.array(command) });
export type Scenario = z.infer<typeof scenarioSchema>;
export class Oracle {
    readonly clients: IdCompressor[];
    constructor(s: Pick<Scenario, 'sessions' | 'version'>) {
        this.clients = s.sessions.map(id => new IdCompressor(assertIsSessionId(id), undefined, s.version));
    }
    apply(c: Command): unknown {
        const a = this.clients[c.client];
        if (!a) throw Error('missing client');
        let value: unknown = null;
        switch (c.kind) {
            case 'load':
                this.clients[c.client] = IdCompressor.deserialize({ serialized: c.serialized as SerializedIdCompressorWithOngoingSession, requestedWriteVersion: 2 });
                break;
            case 'generate':
                value = Array.from({ length: c.count }, () => {
                    const id = a.generateCompressedId();
                    const stable = a.decompress(id);
                    return [id, a.normalizeToOpSpace(id), stable, a.recompress(stable)];
                });
                break;
            case 'capacity':
                Reflect.set(a, 'nextRequestedClusterSize', c.size);
                break;
            case 'take':
                value = a.takeNextCreationRange();
                break;
            case 'reset':
                a.resetUnfinalizedCreationRange();
                break;
            case 'finalize':
                a.finalizeCreationRange({ ...c.range, sessionId: assertIsSessionId(c.range.sessionId) } as IdCreationRange);
                break;
            case 'query': {
                const normalized = a.normalizeToSessionSpace(c.id as OpSpaceCompressedId, assertIsSessionId(c.origin));
                value = [normalized, a.normalizeToOpSpace(normalized), a.decompress(normalized), a.recompress(assertIsStableId(c.stable)), a.tryNormalizeToSessionSpaceWithoutSession(c.id as OpSpaceCompressedId) ?? null];
                break;
            }
            case 'restore':
                this.clients[c.client] = c.local
                    ? IdCompressor.deserialize({ serialized: a.serialize(true), requestedWriteVersion: c.version })
                    : IdCompressor.deserialize({ serialized: a.serialize(false), newSessionId: assertIsSessionId(c.newSession), requestedWriteVersion: c.version });
                break;
        }
        const current = this.clients[c.client];
        if (!current) throw Error('missing current');
        return { value, local: current.serialize(true), summary: current.serialize(false) };
    }
}
export function run(s: Scenario): unknown[] {
    const oracle = new Oracle(s);
    return s.commands.map(c => oracle.apply(c));
}
