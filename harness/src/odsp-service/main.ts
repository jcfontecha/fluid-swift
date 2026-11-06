// `npm run odsp-service -- [--port 7095] [--host 0.0.0.0]`: runs the local ODSP service until
// interrupted and prints the OdspClient connection values. Server-side failures print as they occur.
import { OdspLocalService } from './server.js';

function option(name: string, fallback: string): string {
  const index = process.argv.indexOf(name);
  const value = index < 0 ? undefined : process.argv[index + 1];
  return value ?? fallback;
}

const port = Number(option('--port', '7095'));
const host = option('--host', '0.0.0.0');
const service = await OdspLocalService.start(port, host);
console.log(JSON.stringify({
  ...service.connectionInfo(),
  storageToken: 'storage:<user>',
  pushToken: 'push:<user>',
}, null, 2));
let reported = 0;
const monitor = setInterval(() => {
  for (const failure of service.failures.slice(reported)) {
    console.error(`odsp-service failure: ${failure}`);
  }
  reported = service.failures.length;
}, 500);
const stop = async () => {
  clearInterval(monitor);
  await service.close();
  process.exit(0);
};
process.on('SIGINT', () => void stop());
process.on('SIGTERM', () => void stop());
