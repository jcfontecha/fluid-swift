import assert from 'node:assert/strict';
import { spawn, execFileSync } from 'node:child_process';
import { createInterface } from 'node:readline';
import { resolve } from 'node:path';
import { writeFileSync, mkdirSync } from 'node:fs';
import { z } from 'zod';
import { Random } from '../random.js';
import { outbound, inbound, logger, type Scenario } from './oracle.js';
import { OpSplitter } from '../../node_modules/@fluidframework/container-runtime/lib/opLifecycle/opSplitter.js';
import { OpDecompressor } from '../../node_modules/@fluidframework/container-runtime/lib/opLifecycle/opDecompressor.js';
import { CompressionAlgorithms } from '../../node_modules/@fluidframework/container-runtime/lib/compressionDefinitions.js';
import type { IBatchMessage } from '@fluidframework/container-definitions/internal';
const wireSchema = z.array(z.array(z.object({ contents: z.string(), metadata: z.record(z.string(), z.unknown()).optional(), compression: z.string().optional(), referenceSequenceNumber: z.number() })));
const root = resolve(import.meta.dirname, '../../..');
function generate(seed: number): Scenario {
 const r = new Random(seed); const grouped = seed % 4 !== 0;
 return { grouped, threshold: grouped ? r.pick([1, 256, 614400, 10000000]) : 10000000, chunkSize: r.pick([128, 512, 4096]), batches: Array.from({length: 3}, (_, b) => ({
 ops: Array.from({length: grouped && b === 1 && seed % 17 === 0 ? 0 : r.pick([1,2,5,20])}, () => {
  const n = r.pick(seed % 25 === 0 ? [40000] : [0,1,30,500,4000]);
  return Array.from({length:n}, () => r.pick(['a','b','z','😀','\ud800','"','\\',String(r.uint32())])).join('');
 }), allocation: r.int(3) === 0, ...(b === 1 && grouped ? { batchId: `old_[${seed}]` } : {}) })) };
}
// Reassemble only the compressed transport wrapper, retaining original metadata.
function collapse(batchStream: IBatchMessage[][]): IBatchMessage[] {
 let text = ''; const result: IBatchMessage[] = [];
 const chunkSchema = z.object({ type: z.literal('chunkedOp'), contents: z.object({ chunkId:z.number(), totalChunks:z.number(), contents:z.string(), originalMetadata:z.record(z.string(),z.unknown()).optional(), originalCompression:z.string().optional() }) });
 for (const batch of batchStream) for (const m of batch) {
  const parsed: unknown = JSON.parse(m.contents ?? 'null'); const c = chunkSchema.safeParse(parsed);
  if (!c.success) { result.push(m); continue; }
  text += c.data.contents.contents;
  if (c.data.contents.chunkId === c.data.contents.totalChunks) { result.push({ contents:text, metadata:c.data.contents.originalMetadata, compression:c.data.contents.originalCompression, referenceSequenceNumber:m.referenceSequenceNumber }); text=''; }
 }
 assert.equal(text, ''); return result;
}
function normalized(messages: IBatchMessage[]): unknown[] {
 return messages.map(m => {
  if (m.compression !== 'lz4') return m;
  const d = new OpDecompressor(logger);
  const msg = { ...m, contents:JSON.parse(m.contents ?? ''), type:'op', clientId:'sender', clientSequenceNumber:1, sequenceNumber:1, minimumSequenceNumber:0, timestamp:0, referenceSequenceNumber:m.referenceSequenceNumber ?? 0 };
  d.decompressAndStore(msg); const unpacked = d.unroll(msg);
  return {...m, contents:JSON.stringify(unpacked.contents)};
 });
}
function verifyFraming(wire: IBatchMessage[][], s: Scenario) {
 const expected: IBatchMessage[] = [];
 for (const m of collapse(wire)) {
  if (m.compression !== 'lz4') { expected.push(m); continue; }
  const packed = z.object({packedContents:z.string()}).parse(JSON.parse(m.contents ?? ''));
  if (packed.packedContents.length <= s.chunkSize) { expected.push(m); continue; }
  const ref = m.referenceSequenceNumber ?? 0;
  const splitter = new OpSplitter([], batch => { expected.push(...batch); return 1; }, s.chunkSize, 10000000, logger);
  const last = splitter.splitSingletonBatchMessage({messages:[{...m, referenceSequenceNumber:ref, compression:CompressionAlgorithms.lz4}], referenceSequenceNumber:ref, contentSizeInBytes:packed.packedContents.length});
  expected.push(...last.messages);
 }
 assert.deepEqual(JSON.parse(JSON.stringify(wire.flat())), JSON.parse(JSON.stringify(expected)));
 for (const [i, m] of wire.flat().entries()) assert.equal(JSON.stringify(m.metadata), JSON.stringify(expected[i]?.metadata));
}
const self = process.argv.includes('--self');
const count = Number(process.argv.find(a => a.startsWith('--seeds='))?.split('=')[1] ?? 1000);
if (!self) execFileSync('swift',['build','--scratch-path','.build/h1','--product','FluidOpLifecyclePeer','-c','release'],{cwd:root,stdio:'inherit'});
const child = self ? undefined : spawn(resolve(root,'.build/h1/release/FluidOpLifecyclePeer'),[],{stdio:['pipe','pipe','inherit']});
const lines = child ? createInterface({input:child.stdout})[Symbol.asyncIterator]() : undefined;
async function call(method:string,value:unknown):Promise<unknown> { assert(child && lines); child.stdin.write(JSON.stringify({method,value})+'\n'); let timer:NodeJS.Timeout|undefined; const line=await Promise.race([lines.next(),new Promise<never>((_,reject)=>{timer=setTimeout(()=>reject(Error('peer timeout')),30000);})]).finally(()=>clearTimeout(timer)); assert(!line.done,'peer exited'); return JSON.parse(line.value); }
let seed=0; let scenario:Scenario|undefined;
try {
 for (;seed<count;seed++) {
  if (seed > 0 && seed % 100 === 0) console.log(`${seed} seeds passed`);
  scenario=generate(seed); const ts=outbound(scenario); const swift=self ? outbound(scenario) : wireSchema.parse(await call('outbound',scenario));
  assert.deepEqual(JSON.parse(JSON.stringify(normalized(collapse(swift)))), JSON.parse(JSON.stringify(normalized(collapse(ts)))),`outbound seed ${seed}`);
  verifyFraming(swift,scenario);
  assert.deepEqual(self ? inbound(ts) : await call('inbound',ts), inbound(ts),`TS -> Swift seed ${seed}`);
  assert.deepEqual(self ? inbound(swift) : await call('inbound',swift),inbound(swift),`Swift -> TS seed ${seed}`);
 }
 console.log(`${self?'TS self-check':'Swift differential'}: ${count} seeds passed both directions`);
} catch(error) { mkdirSync(resolve(root,'harness/traces/oplifecycle'),{recursive:true}); writeFileSync(resolve(root,`harness/traces/oplifecycle/${seed}.json`),JSON.stringify({seed,scenario,error:String(error)},null,2)); throw error; }
finally { child?.kill(); }
