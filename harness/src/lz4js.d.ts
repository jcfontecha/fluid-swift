// lz4js 0.2.0 ships no type declarations; these cover the two calls the harness makes.
declare module "lz4js" {
  const lz4: {
    compress(source: ArrayLike<number>): Uint8Array;
    decompress(source: ArrayLike<number>): Uint8Array;
  };
  export default lz4;
}
