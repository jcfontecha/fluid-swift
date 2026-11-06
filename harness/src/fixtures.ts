import { writeFile } from "node:fs/promises";
import { Random } from "./random.js";
const random = new Random(0x5eed1234);
const bytes = new DataView(new ArrayBuffer(8));
function bits(value: number): string {
  bytes.setFloat64(0, value, false);
  return bytes.getBigUint64(0, false).toString(16).padStart(16, "0");
}
function fromBits(high: number, low: number): number {
  bytes.setUint32(0, high, false);
  bytes.setUint32(4, low, false);
  return bytes.getFloat64(0, false);
}
const numbers = [
  0,
  -0,
  NaN,
  Infinity,
  -Infinity,
  Number.MIN_VALUE,
  -Number.MIN_VALUE,
  Number.MAX_VALUE,
  -Number.MAX_VALUE,
  Number.MAX_SAFE_INTEGER - 1,
  Number.MAX_SAFE_INTEGER,
  Number.MAX_SAFE_INTEGER + 1,
  0.1 + 0.2,
  2 ** -1022,
  2 ** -1022 - Number.MIN_VALUE,
];
for (let exponent = -10; exponent <= 25; exponent++)
  for (const sign of [1, -1]) numbers.push(sign * 10 ** exponent);
for (let i = 0; i < 1000; i++)
  numbers.push(fromBits(random.uint32(), random.uint32()));
const decimals = [
  "1E5",
  "1e-0",
  "-0",
  "1.0",
  "123456789012345678901234567890.123456789",
  "0.1000000000000000055511151231257827021181583404541015625",
  "2.4703282292062327e-324",
  "2.4703282292062328e-324",
  "5e-324",
  "1e-400",
  "-1e-400",
  "1.7976931348623157e308",
  "1.7976931348623159e308",
  "-1e309",
  "1e309",
  "9007199254740993",
  "999999999999999999999",
  "1e-7",
  "1e-6",
  "1e20",
  "1e21",
];
for (let i = 0; i < 1000; i++) {
  const text = `${random.int(2) ? "-" : ""}${random.int(1000000000)}.${String(random.uint32()).padStart(10, "0")}e${random.int(651) - 325}`;
  decimals.push(text);
  numbers.push(Number(text));
}
const units: number[][] = [
  [],
  [0x22],
  [0x5c],
  Array.from({ length: 32 }, (_, i) => i),
  [0x7f, 0x2028, 0x2029],
  [0xd83d, 0xde00],
  [0xd800],
  [0xdc00],
  [0xd800, 0x61, 0xdc00],
  [0xffff, 0xfffe],
];
const special = [
  0, 8, 9, 10, 12, 13, 0x22, 0x5c, 0x7f, 0x2028, 0x2029, 0xd800, 0xdbff, 0xdc00,
  0xdfff,
];
for (let i = 0; i < 400; i++)
  units.push(
    Array.from({ length: random.int(40) }, () =>
      random.int(2) ? random.pick(special) : random.int(65536),
    ),
  );
const orders = [
  ["b", "10", "2", "a", "0", "01", "-1", "4294967294", "4294967295", "1.5"],
  ["x", "y", "x", "2", "1", "2", "z", "y"],
  ["4294967295", "4294967294", "01", "1", "0", "-0", "00"],
  ["__proto__", "constructor", "toString", "1", "__proto__"],
];
for (let i = 0; i < 100; i++)
  orders.push(
    Array.from({ length: 20 }, () =>
      random.pick([
        "a",
        "b",
        "z",
        "0",
        "1",
        "10",
        "2",
        "01",
        "-1",
        "4294967294",
        "4294967295",
        "1.5",
      ]),
    ),
  );
const fixture = {
  stringifyNumbers: numbers.map((value) => ({
    bits: bits(value),
    json: JSON.stringify(value),
  })),
  parseNumbers: decimals.map((json) => ({
    json,
    bits: bits(Number(JSON.parse(json))),
  })),
  strings: units.map((utf16) => ({
    utf16,
    json: JSON.stringify(String.fromCharCode(...utf16)),
  })),
  objects: orders.map((insertionOrder) => {
    // CreateDataProperty semantics (as JSON.parse): "__proto__" is an own key, not the setter.
    const object: Record<string, number> = {};
    insertionOrder.forEach((key, index) => {
      Object.defineProperty(object, key, {
        value: index,
        enumerable: true,
        writable: true,
        configurable: true,
      });
    });
    return { insertionOrder, json: JSON.stringify(object) };
  }),
};
await writeFile(
  new URL("../fixtures/js-semantics.json", import.meta.url),
  JSON.stringify(fixture, null, 2) + "\n",
);
console.log(
  `Generated ${numbers.length} stringify, ${decimals.length} parse, ${units.length} string, ${orders.length} object cases`,
);
