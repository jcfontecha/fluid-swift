// Run the existing gates unchanged except for L8's reserved ports and scratch directory.
// Copies live here, so no concurrently-owned harness sources are edited.
import { readFileSync, writeFileSync, unlinkSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
const name = process.argv[2];
const modes = new Map([
    ['service', ['../service.ts', 7084]],
    ['service:m2', ['../service-m2.ts', 7084]],
    ['service:m3', ['../service-m3.ts', 7084]],
    ['service:presence', ['../service-presence.ts', 7084]],
    ['fuzz:odsp-service', ['../odsp-net/service/fuzz.ts', 7086]],
]);
if (!modes.has(name)) throw new Error('Choose an existing service gate');
const [source,port] = modes.get(name);
let code = readFileSync(new URL(source, import.meta.url), 'utf8');
if (name === 'fuzz:odsp-service') {
    code = code.replaceAll("from './", "from '../odsp-net/service/")
        .replaceAll('7091', String(port)).replaceAll('.build/odsp-service', '.build/create');
} else {
    code = code.replaceAll("from './", "from '../")
        .replaceAll("from '../node_modules/", "from '../../node_modules/")
        .replaceAll("resolve(import.meta.dirname, '../..')", "resolve(import.meta.dirname, '../../..')")
        .replace(/707[3456]/g, String(port));
}
const copy = new URL(`./.regression-${name.replaceAll(':','-')}.ts`, import.meta.url);
writeFileSync(copy, code);
try {
    const result = spawnSync('node', ['--import','tsx',copy.pathname,'--scratch-path=.build/create',...process.argv.slice(3)], {
        cwd:new URL('../..',import.meta.url),stdio:'inherit',
    });
    process.exitCode = result.status ?? 1;
} finally {
    unlinkSync(copy);
}
