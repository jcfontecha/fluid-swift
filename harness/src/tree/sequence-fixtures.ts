import { writeFileSync } from 'node:fs';
import { sequenceFieldEditor as editor } from '../../node_modules/@fluidframework/tree/lib/feature-libraries/sequence-field/sequenceFieldEditor.js';
import { brand } from '../../node_modules/@fluidframework/tree/lib/util/index.js';
import type { ChangeAtomId } from '../../node_modules/@fluidframework/tree/lib/core/index.js';
import { Random } from '../random.js';
const fixtures = Array.from({ length: 1000 }, (_, seed) => {
    const random = new Random(seed);
    const index = random.int(12);
    const count = random.int(5);
    const destination = random.int(18);
    const atom: ChangeAtomId = { localId: brand(8), revision: 'root' as const };
    return {
        index, count, destination,
        insert: editor.insert(index, count, atom, 'root'),
        remove: editor.remove(index, count, brand(0), 'root'),
        revive: editor.revive(index, count, atom, 'root'),
        move: editor.move(index, count, destination, brand(0), atom, 'root'),
        moveIn: editor.moveIn(destination, count, brand(0), atom, 'root'),
        moveOut: editor.moveOut(index, count, brand(0), 'root'),
        return: editor.return(index, count, destination, { localId: brand(32), revision: 'root' }, atom, 'root'),
    };
});
writeFileSync('../Tests/FluidTreeTests/Fixtures/sequence-editors.json', JSON.stringify(fixtures));
console.log(`Generated ${fixtures.length} real-TS sequence editor fixtures`);
