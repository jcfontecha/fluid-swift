// The TypeScript side of CreateContainerEndToEndTests: a real 3.11.0 service client that loads a
// Swift-created container. Run from harness/ (so its node_modules resolve) as
// `node --input-type=module --eval <this file> odsp <siteUrl> <driveId> <itemId>` or
// `node --input-type=module --eval <this file> tinylicious <port> <id>`.
// It loads the `{ text: SharedString, map: SharedMap }` container, waits until it is connected,
// and prints one view: `{"text","map","dirty"}`, map as an object of its entries. Then each stdin
// line is a request, answered by one view: `{"op":"insert","pos","text"}` inserts first; any
// other request only reads. Closing stdin disposes the container and exits.
import { createInterface } from 'node:readline';
import { once } from 'node:events';
import { OdspClient } from '@fluidframework/odsp-client/beta';
import { TinyliciousClient } from '@fluidframework/tinylicious-client';
import { SharedMap, SharedString } from 'fluid-framework/legacy';

const [service, ...rest] = process.argv.slice(1);
const schema = { initialObjects: { text: SharedString, map: SharedMap } };

let container;
if (service === 'odsp') {
  const [siteUrl, driveId, itemId] = rest;
  const client = new OdspClient({
    connection: {
      siteUrl,
      driveId,
      filePath: '',
      tokenProvider: {
        fetchStorageToken: async () => ({ token: 'storage:ts' }),
        fetchWebsocketToken: async () => ({ token: 'push:ts' }),
      },
    },
  });
  ({ container } = await client.getContainer(itemId, schema));
} else if (service === 'tinylicious') {
  const [port, id] = rest;
  const client = new TinyliciousClient({ connection: { port: Number(port) } });
  ({ container } = await client.getContainer(id, schema, '2.0.0'));
} else {
  throw new Error(`unknown service ${service}`);
}
if (container.connectionState !== 2) {
  await once(container, 'connected');
}
const { text, map } = container.initialObjects;

function view() {
  return { text: text.getText(), map: Object.fromEntries(map.entries()), dirty: container.isDirty };
}

process.stdout.write(JSON.stringify(view()) + '\n');
for await (const line of createInterface({ input: process.stdin })) {
  const request = JSON.parse(line);
  if (request.op === 'insert') {
    text.insertText(request.pos, request.text);
  }
  process.stdout.write(JSON.stringify(view()) + '\n');
}
container.dispose();
process.exit(0);
