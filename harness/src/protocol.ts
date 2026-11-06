import { z } from "zod";
export const ddsType = "https://graph.microsoft.com/types/counter";
export const summarySchema = z
  .object({
    type: z.literal(1),
    tree: z.record(
      z.string(),
      z.object({ type: z.literal(2), content: z.string() }).strict(),
    ),
  })
  .strict();
export const outboundSchema = z
  .object({
    clientId: z.string(),
    clientSequenceNumber: z.number().int().positive(),
    referenceSequenceNumber: z.number().int().nonnegative(),
    contents: z.json(),
  })
  .strict();
export const messageSchema = outboundSchema.extend({
  sequenceNumber: z.number().int().positive(),
  minimumSequenceNumber: z.number().int().nonnegative(),
  type: z.literal("op"),
});
export const editSchema = z.discriminatedUnion("kind", [
  z.object({ kind: z.literal("increment"), amount: z.number() }),
  z.object({
    kind: z.literal("set"),
    valueKind: z.enum(["undefined", "handle"]).optional(),
    key: z.string(),
    value: z.json(),
    path: z.string().optional(),
  }),
  z.object({
    kind: z.literal("delete"),
    index: z.number().int().nonnegative().optional(),
    key: z.string(),
    path: z.string().optional(),
  }),
  z.object({ kind: z.literal("clear"), path: z.string().optional() }),
  z.object({
    kind: z.enum(["createSubDirectory", "deleteSubDirectory"]),
    path: z.string(),
    name: z.string(),
  }),
  z.object({
    kind: z.enum(["volunteer", "subscribe", "abandon", "complete"]),
    key: z.string(),
  }),
  z.object({
    kind: z.enum(["add", "insert", "notify"]),
    index: z.number().int().nonnegative().optional(),
    value: z.json(),
  }),
  z.object({
    kind: z.literal("acquire"),
    result: z.enum(["complete", "release"]).optional(),
  }),
  z.object({
    kind: z.literal("move"),
    oldIndex: z.number().int().nonnegative(),
    newIndex: z.number().int().nonnegative(),
  }),
  z.object({
    kind: z.literal("toggle"),
    entryId: z.string(),
  }),
  z.object({
    kind: z.literal("toggleMove"),
    oldEntryId: z.string(),
    newEntryId: z.string(),
  }),
  z.object({
    kind: z.literal("insertBulkAfter"),
    ref: z.json().optional(),
    values: z.array(z.json()),
  }),
]);
export type Edit = z.infer<typeof editSchema>;
const client = z.object({ clientId: z.string() }).strict();
export const requestSchema = z.discriminatedUnion("method", [
  z.object({ method: z.literal("hello"), params: z.object({}).strict() }),
  z.object({ method: z.literal("reset"), params: z.object({}).strict() }),
  z.object({
    method: z.literal("createClient"),
    params: client.extend({
      ddsType: z.string(),
      channelId: z.string(),
      sequenceNumber: z.number().int().nonnegative(),
      summary: summarySchema.nullable(),
      members: z.array(z.string()).optional(),
      flushMode: z.enum(["immediate", "turnBased"]).optional(),
    }),
  }),
  z.object({
    method: z.literal("edit"),
    params: client.extend({
      edit: editSchema,
    }),
  }),
  z.object({
    method: z.literal("process"),
    params: client.extend({ message: messageSchema }),
  }),
  z.object({ method: z.enum(["flush", "rollback"]), params: client }),
  z.object({
    method: z.literal("stash"),
    params: client.extend({ contents: z.json() }),
  }),
  z.object({ method: z.literal("disconnect"), params: client }),
  z.object({
    method: z.literal("reconnect"),
    params: client.extend({ newClientId: z.string() }),
  }),
  z.object({
    method: z.literal("membership"),
    params: client.extend({ members: z.array(z.string()) }),
  }),
  ...(
    ["state", "queries", "summarize", "events", "disposeClient"] as const
  ).map((method) => z.object({ method: z.literal(method), params: client })),
]);
export type Request = z.infer<typeof requestSchema>;
export type Outbound = z.infer<typeof outboundSchema>;
export type Message = z.infer<typeof messageSchema>;
export type Summary = z.infer<typeof summarySchema>;
export const rpcResponseSchema = z.object({
  jsonrpc: z.literal("2.0"),
  id: z.number().int(),
  result: z.unknown().optional(),
  error: z.object({ code: z.number(), message: z.string() }).optional(),
});
export const outboundResult = z
  .object({ outbound: z.array(outboundSchema) })
  .strict();
