// Real 3.11.0 detached clients; these fixtures pin blob strings and property order.
import { writeFileSync } from 'node:fs';
import { OdspClient } from '@fluidframework/odsp-client';
import { SharedMap } from '@fluidframework/map/internal';
import { SharedString } from '@fluidframework/sequence/internal';
const fixtures = [];
for (let seed = 0; seed < 10; seed++) {
    const client = new OdspClient({connection:{siteUrl:'http://localhost:7085',driveId:'b!bG9jYWwtb2RzcA',tokenProvider:{fetchStorageToken:async()=>({token:'storage:l8'}),fetchWebsocketToken:async()=>({token:'push:l8'})}}});
    const {container} = await client.createContainer({initialObjects:{text:SharedString,map:SharedMap}});
    const compressor = container.container.runtime.idCompressor;
    const sessionId = compressor.localSessionId;
    for (let i = 0; i < seed; i++) compressor.generateCompressedId();
    const edits = [];
    for (let step = 0; step < 12; step++) {
        const text = `${seed}:${step}é `;
        const key = String((seed * 7 + step * 3) % 9);
        const value = seed * 31 + step;
        edits.push({text,key,value});
        container.initialObjects.text.insertText(0, text);
        container.initialObjects.map.set(key, value);
    }
    let summary;
    client.documentServiceFactory.createContainer = async (uploaded) => {
        summary = uploaded;
        throw new Error('captured at createContainer boundary');
    };
    try {
        await container.attach();
    } catch (error) {
        if (summary === undefined) throw error;
    }
    fixtures.push({seed,sessionId,edits,summary});
    container.dispose();
}
writeFileSync(new URL('../../../Tests/FluidStaticTests/Fixtures/create.json', import.meta.url), JSON.stringify(fixtures));
console.log('Wrote 10 detached TS oracle seeds');
