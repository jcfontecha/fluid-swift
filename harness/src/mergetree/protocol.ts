import { z } from 'zod';
export const editSchema = z.discriminatedUnion('kind', [
    z.object({ kind: z.literal('insert'), pos: z.number().int().nonnegative(), text: z.string() }),
    z.object({ kind: z.literal('marker'), pos: z.number().int().nonnegative() }),
    z.object({ kind: z.enum(['remove', 'obliterate', 'annotate']), start: z.number().int().nonnegative(), end: z.number().int().nonnegative(), props: z.record(z.string(), z.union([z.string(), z.number(), z.null()])).optional() }),
    z.object({ kind: z.literal('reference'), pos: z.number().int().nonnegative(), id: z.string(), refType: z.union([z.literal(64), z.literal(128), z.literal(256)]) }),
]);
export type Edit = z.infer<typeof editSchema>;
export const requestSchema = z.object({ jsonrpc: z.literal('2.0'), id: z.number().int(), method: z.enum(['reset', 'create', 'edit', 'process', 'state', 'minSeq', 'snapshot']), params: z.object({ client: z.string().optional(), obliterate: z.boolean().optional(), edit: editSchema.optional(), message: z.unknown().optional(), seq: z.number().int().optional(), version: z.enum(['legacy', 'v1']).optional() }) });
export const messageSchema = z.object({ clientId: z.string(), clientSequenceNumber: z.number().int(), referenceSequenceNumber: z.number().int(), sequenceNumber: z.number().int(), minimumSequenceNumber: z.number().int(), type: z.literal('op'), contents: z.unknown() });
export const stateSchema = z.object({ text: z.array(z.number().int()), length: z.number().int(), segments: z.array(z.unknown()), references: z.record(z.string(), z.number().int()), lengths: z.array(z.number().int()) });
