// The TypeScript side of OdspClientEndToEndTests: a real 3.11.0 `OdspClient` on the local ODSP
// service. Run from harness/ (so its node_modules resolve) as
// `node --input-type=module --eval <this file> <siteUrl> <driveId> <user>`.
// It creates and attaches a `{ text: SharedString }` container, types "TS: hello" once attached,
// and prints `{"itemId"}` when that edit is saved. Then each stdin line is a request, answered by
// one stdout line with the current text: `{"op":"insert","pos","text"}` inserts first; any other
// request only reads. Closing stdin disposes the container and exits.
import { createInterface } from 'node:readline';
import { once } from 'node:events';
import { OdspClient } from '@fluidframework/odsp-client/beta';
import { SharedString } from 'fluid-framework/legacy';

const [siteUrl, driveId, user] = process.argv.slice(1);
const client = new OdspClient({
  connection: {
    siteUrl,
    driveId,
    filePath: '',
    tokenProvider: {
      fetchStorageToken: async () => ({ token: `storage:${user}` }),
      fetchWebsocketToken: async () => ({ token: `push:${user}` }),
    },
  },
});
const { container } = await client.createContainer({ initialObjects: { text: SharedString } });
const itemId = await container.attach();
const text = container.initialObjects.text;
text.insertText(0, 'TS: hello');
if (container.isDirty) {
  await once(container, 'saved');
}
process.stdout.write(JSON.stringify({ itemId }) + '\n');

for await (const line of createInterface({ input: process.stdin })) {
  const request = JSON.parse(line);
  if (request.op === 'insert') {
    text.insertText(request.pos, request.text);
  }
  process.stdout.write(JSON.stringify({ text: text.getText(), dirty: container.isDirty }) + '\n');
}
container.dispose();
process.exit(0);
