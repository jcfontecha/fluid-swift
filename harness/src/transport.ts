import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { createInterface } from "node:readline";
import { once } from "node:events";
import { rpcResponseSchema, type Request } from "./protocol.js";
export const harnessRoot = fileURLToPath(new URL("../", import.meta.url));
export const repoRoot = fileURLToPath(new URL("../../", import.meta.url));
export type PeerKind = "ts" | "swift";
export type TraceEntry = {
  peer: number;
  direction: "request" | "response";
  payload: unknown;
};
export class Peer {
  private readonly child: ChildProcessWithoutNullStreams;
  private readonly lines: AsyncIterator<string>;
  private id = 0;
  private stderr = "";
  private failure: Error | undefined;
  constructor(
    readonly kind: PeerKind,
    readonly index: number,
    private readonly trace: TraceEntry[],
  ) {
    const binary = `${repoRoot}.build/debug/fluid-swift-peer`;
    if (kind === "swift" && !existsSync(binary))
      throw new Error(
        `Swift peer binary missing: ${binary}; build it with swift build first`,
      );
    this.child =
      kind === "swift"
        ? spawn(binary, [], { cwd: repoRoot })
        : spawn(
            process.execPath,
            ["--import", "tsx", `${harnessRoot}src/peer.ts`],
            { cwd: harnessRoot },
          );
    this.child.on("error", (error) => {
      this.failure = error;
    });
    this.child.stderr.on("data", (chunk: Buffer) => {
      this.stderr += chunk.toString();
    });
    this.lines = createInterface({ input: this.child.stdout })[
      Symbol.asyncIterator
    ]();
  }
  async call(request: Request): Promise<unknown> {
    const payload = { jsonrpc: "2.0", id: ++this.id, ...request };
    this.trace.push({ peer: this.index, direction: "request", payload });
    this.child.stdin.write(JSON.stringify(payload) + "\n");
    let timer: ReturnType<typeof setTimeout> | undefined;
    const line = await Promise.race([
      this.lines.next(),
      new Promise<never>((_, reject) => {
        timer = setTimeout(
          () =>
            reject(new Error(`Peer ${this.index} timed out: ${this.stderr}`)),
          10000,
        );
      }),
    ]).finally(() => {
      clearTimeout(timer);
    });
    if (line.done)
      throw (
        this.failure ?? new Error(`Peer ${this.index} exited: ${this.stderr}`)
      );
    const raw: unknown = JSON.parse(line.value);
    this.trace.push({ peer: this.index, direction: "response", payload: raw });
    const response = rpcResponseSchema.parse(raw);
    if (response.id !== this.id) throw new Error("Response id mismatch");
    if (response.error)
      throw new Error(`Peer ${this.index}: ${response.error.message}`);
    if (!Object.hasOwn(response, "result"))
      throw new Error("Missing RPC result");
    return response.result;
  }
  async close(): Promise<void> {
    if (this.child.exitCode !== null || this.child.signalCode !== null) return;
    const exited = once(this.child, "exit");
    this.child.kill();
    await exited;
  }
}
