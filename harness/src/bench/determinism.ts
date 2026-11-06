// Installed before Fluid/uuid are evaluated. Only fixture generation overrides entropy/time.
import crypto from 'node:crypto';
import { syncBuiltinESMExports } from 'node:module';
if (process.argv[2] === 'generate') {
    let state = 0x12345678;
    crypto.randomFillSync = ((buffer: NodeJS.ArrayBufferView, offset = 0, size?: number) => {
        const bytes = new Uint8Array(buffer.buffer, buffer.byteOffset, buffer.byteLength);
        for (let i = offset; i < offset + (size ?? bytes.length - offset); i++) {
            state = (Math.imul(state, 1664525) + 1013904223) >>> 0;
            bytes[i] = state >>> 24;
        }
        return buffer;
    }) as typeof crypto.randomFillSync;
    crypto.randomUUID = () => {
        const bytes = crypto.randomFillSync(new Uint8Array(16));
        bytes[6] = (bytes[6]! & 15) | 64;
        bytes[8] = (bytes[8]! & 63) | 128;
        const h = Buffer.from(bytes).toString('hex');
        return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`;
    };
    Date.now = () => 1700000000000;
    syncBuiltinESMExports();
}
