import { createInterface } from 'node:readline';
import { once } from 'node:events';
import { OdspClient } from '@fluidframework/odsp-client';
import { AzureClient } from '@fluidframework/azure-client';
import { InsecureTinyliciousTokenProvider } from '@fluidframework/tinylicious-driver/internal';
import { TinyliciousClient } from '@fluidframework/tinylicious-client';
import { SharedString } from '@fluidframework/sequence/internal';
import { SharedMap } from '@fluidframework/map/internal';
const [kind, port, id] = process.argv.slice(2);
const client = kind === 'odsp'
    ? new OdspClient({connection:{siteUrl:`http://localhost:${port}`,driveId:'b!bG9jYWwtb2RzcA',tokenProvider:{fetchStorageToken:async()=>({token:'storage:ts'}),fetchWebsocketToken:async()=>({token:'push:ts'})}}})
    : kind === 'azure'
        ? new AzureClient({connection:{type:'local',endpoint:`http://localhost:${port}`,tokenProvider:new InsecureTinyliciousTokenProvider()}})
        : new TinyliciousClient({connection:{port:Number(port)}});
const schema = {initialObjects:{text:SharedString,map:SharedMap}};
const {container} = id === 'new'
    ? await client.createContainer(schema, '2.0.0')
    : await client.getContainer(id, schema, '2.0.0');
const {text,map} = container.initialObjects;
let itemId = id;
if (id === 'new') {
    text.insertText(0, 'detached');
    map.set('origin', 'detached');
    itemId = await container.attach();
}
if (container.connectionState !== 2) await once(container, 'connected');
function view() {
    return {itemId,text:text.getText(),map:[...map.entries()].map(([key,value]) => [key,value?.absolutePath ? {$handle:value.absolutePath} : value]),dirty:container.isDirty};
}
console.log(JSON.stringify(view()));
for await (const line of createInterface({input:process.stdin})) {
    const request = JSON.parse(line);
    if (request.op === 'blob') {
        console.log(JSON.stringify({bytes:[...new Uint8Array(await map.get('blob').get())]}));
        continue;
    }
    if (request.op === 'edit') {
        text.insertText(0, 'TS ');
        map.set('ts', 2);
    }
    console.log(JSON.stringify(view()));
}
container.dispose();
process.exit(0);
