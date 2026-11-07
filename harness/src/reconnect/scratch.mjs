import childProcess from 'node:child_process';
import { syncBuiltinESMExports } from 'node:module';
const execFileSync = childProcess.execFileSync;
const spawn = childProcess.spawn;
childProcess.execFileSync = function(file, args, options) {
    if (file === 'swift' && Array.isArray(args)) {
        args = [...args];
        const index = args.indexOf('--scratch-path');
        if (index >= 0) args[index + 1] = '.build/reconnect';
    }
    return execFileSync.call(this, file, args, options);
};
childProcess.spawn = function(file, ...args) {
    file = file.replace('/.build/odsp-service/', '/.build/reconnect/').replace('/.build/l10/', '/.build/reconnect/');
    return spawn.call(this, file, ...args);
};
syncBuiltinESMExports();
