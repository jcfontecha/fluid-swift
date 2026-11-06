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
    contents: z
      .object({
        type: z.literal("increment"),
        incrementAmount: z
          .number()
          .refine(Number.isInteger, "Expected integer-valued double"),
      })
      .strict(),
  })
  .strict();
export const messageSchema = outboundSchema.extend({
  sequenceNumber: z.number().int().positive(),
  minimumSequenceNumber: z.number().int().nonnegative(),
  type: z.literal("op"),
});
const client = z.object({ clientId: z.string() }).strict();
export const requestSchema = z.discriminatedUnion("method", [
  z.object({ method: z.literal("hello"), params: z.object({}).strict() }),
  z.object({
    method: z.literal("createClient"),
    params: client.extend({
      ddsType: z.literal(ddsType),
      channelId: z.string(),
      sequenceNumber: z.number().int().nonnegative(),
      summary: summarySchema.nullable(),
    }),
  }),
  z.object({
    method: z.literal("edit"),
    params: client.extend({
      edit: z
        .object({
          kind: z.literal("increment"),
          amount: z
            .number()
            .refine(Number.isInteger, "Expected integer-valued double"),
        })
        .strict(),
    }),
  }),
  z.object({
    method: z.literal("process"),
    params: client.extend({ message: messageSchema }),
  }),
  ...(["state", "summarize", "disposeClient"] as const).map((method) =>
    z.object({ method: z.literal(method), params: client }),
  ),
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
