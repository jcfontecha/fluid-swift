import { spawnSync } from 'node:child_process';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
const root = fileURLToPath(new URL('../../..', import.meta.url));
const odsp = process.argv.includes('--odsp');
const crossLoad = odsp || process.argv.includes('--cross-load');
const target = crossLoad ? 'FluidCreationTests' : 'FluidStaticTests';
function run(command, args, options = {}) {
    const result = spawnSync(command, args, {cwd:root,stdio:'inherit',...options});
    if (result.error) throw result.error;
    return result.status ?? 1;
}
if (!process.argv.includes('--skip-build')) {
    const status = run('swift', ['build','--scratch-path','.build/create','--target',target]);
    if (status !== 0) process.exit(status);
}
// Swift 6.4's test products are bundles. Select just this lane's bundle so another lane's
// half-authored test target cannot prevent this gate from running.
const swift = spawnSync('xcrun',['--find','swift'],{encoding:'utf8'}).stdout.trim();
const platform = spawnSync('xcrun',['--show-sdk-platform-path'],{encoding:'utf8'}).stdout.trim();
const helper = resolve(dirname(swift),'../libexec/swift/pm/swiftpm-testing-helper');
const bundle = resolve(root,`.build/create/debug/${target}.xctest/Contents/MacOS/${target}`);
const status = run(helper,['--test-bundle-path',bundle,'--filter',odsp ? 'CrossLoadTests/odsp' : crossLoad ? 'CrossLoadTests' : 'DetachedCreationTests','--testing-library','swift-testing'],{
    env:{...process.env,
        DYLD_FRAMEWORK_PATH:resolve(platform,'Developer/Library/Frameworks'),
        DYLD_LIBRARY_PATH:resolve(platform,'Developer/usr/lib'),
        ...(process.argv.includes('--plant-divergence') ? {L8_PLANT_DIVERGENCE:'1'} : {}),
    },
});
process.exit(status);
