// The TypeScript side of FluidAzureClientTests' end-to-end tests: a real 3.11.0 service client on
// a local tinylicious. Run from harness/ as
// `node --import tsx src/azure-client/ts-client.ts <azure|tinylicious> <port> <user>`.
// `azure` is `AzureClient` with an `AzureLocalConnectionConfig`; `tinylicious` is
// `TinyliciousClient`. Both sign tokens for `{ id: user, name: user }`.
// It creates and attaches a `{ text: SharedString, map: SharedMap }` container, types "TS: hello"
// and sets map "ts" to "hello" once attached, and prints `{"id"}` when those edits are saved.
// Then each stdin line is a request, answered by one stdout line:
//   {"op":"insert","pos","text"} and {"op":"set","key","value"} edit, then answer like "view";
//   {"op":"view"} answers {"text","map","dirty"}, map as an object of its entries;
//   {"op":"members"} answers {"members"}: each audience member's {id, name, connections}, by user id;
//   {"op":"versions"} (azure only) answers {"versions"} from `getContainerVersions`.
// Closing stdin disposes the container and exits.
import { createInterface } from 'node:readline';

import { AzureClient } from '@fluidframework/azure-client';
import type { ContainerSchema, IFluidContainer, IServiceAudience, IMember } from '@fluidframework/fluid-static';
import { InsecureTokenProvider } from '@fluidframework/test-runtime-utils/internal';
import { TinyliciousClient } from '@fluidframework/tinylicious-client';
import { SharedMap, SharedString } from 'fluid-framework/legacy';

const [service, portArgument, user] = process.argv.slice(2);
if (service !== 'azure' && service !== 'tinylicious') {
  throw new Error(`unknown service ${service}`);
}
if (portArgument === undefined || user === undefined) {
  throw new Error('usage: ts-client.ts <azure|tinylicious> <port> <user>');
}
const port = Number(portArgument);
const tokenProvider = new InsecureTokenProvider('fooBar', { id: user, name: user });
const schema = {
  initialObjects: { text: SharedString, map: SharedMap },
} satisfies ContainerSchema;

const azureClient = service === 'azure'
  ? new AzureClient({ connection: { type: 'local', endpoint: `http://localhost:${port}`, tokenProvider } })
  : undefined;
const tinyliciousClient = service === 'tinylicious'
  ? new TinyliciousClient({ connection: { port, tokenProvider } })
  : undefined;

let container: IFluidContainer<typeof schema>;
let audience: IServiceAudience<IMember>;
if (azureClient !== undefined) {
  const created = await azureClient.createContainer(schema, '2.0.0');
  container = created.container;
  audience = created.services.audience;
} else if (tinyliciousClient !== undefined) {
  const created = await tinyliciousClient.createContainer(schema, '2.0.0');
  container = created.container;
  audience = created.services.audience;
} else {
  throw new Error('no client');
}

const id = await container.attach();
const text = container.initialObjects.text;
const map = container.initialObjects.map;
text.insertText(0, 'TS: hello');
map.set('ts', 'hello');
if (container.isDirty) {
  await new Promise<void>(resolve => container.once('saved', () => resolve()));
}
process.stdout.write(JSON.stringify({ id }) + '\n');

function view(): object {
  return { text: text.getText(), map: Object.fromEntries(map.entries()), dirty: container.isDirty };
}

for await (const line of createInterface({ input: process.stdin })) {
  const request = JSON.parse(line);
  if (request.op === 'insert') {
    text.insertText(request.pos, request.text);
    process.stdout.write(JSON.stringify(view()) + '\n');
  } else if (request.op === 'set') {
    map.set(request.key, request.value);
    process.stdout.write(JSON.stringify(view()) + '\n');
  } else if (request.op === 'members') {
    const members = Object.fromEntries(audience.getMembers());
    process.stdout.write(JSON.stringify({ members }) + '\n');
  } else if (request.op === 'versions') {
    if (azureClient === undefined) {
      throw new Error('versions needs the azure client');
    }
    const versions = await azureClient.getContainerVersions(id);
    process.stdout.write(JSON.stringify({ versions }) + '\n');
  } else {
    process.stdout.write(JSON.stringify(view()) + '\n');
  }
}
container.dispose();
process.exit(0);
