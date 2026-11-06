/** Build only the unpublished RNG dependency used by the pinned upstream test helpers. */
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import ts from 'typescript';

export function prepareObliterate(): void {
    const source = new URL('../../../reference/fluidframework-3.11.0/packages/test/stochastic-test-utils/src/', import.meta.url);
    const destination = new URL('../../node_modules/@fluid-private/stochastic-test-utils/', import.meta.url);
    const files = ['random', 'types', 'xsadd', 'distributions/index', 'distributions/integer', 'distributions/normal', 'distributions/real'];
    for (const file of files) {
        const input = readFileSync(new URL(`${file}.ts`, source), 'utf8');
        const output = ts.transpileModule(input, {
            compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.ES2022 },
            fileName: `${file}.ts`,
        });
        const path = fileURLToPath(new URL(`${file}.js`, destination));
        mkdirSync(dirname(path), { recursive: true });
        writeFileSync(path, output.outputText);
    }
    writeFileSync(new URL('package.json', destination), JSON.stringify({
        name: '@fluid-private/stochastic-test-utils',
        version: '3.11.0',
        private: true,
        type: 'module',
        exports: './random.js',
    }));
}
