// Ordering for the local ODSP service. Sequencing is the real Fluid server code (deli, broadcaster
// and scriptorium inside @fluidframework/server-memory-orderer 7.0.1 `LocalOrderer`); this file
// only wires it per file and adds the ODSP storage lambda that tinylicious' scribe would otherwise
// fill: it persists the sequenced op stream and acks single-commit summaries.
import { z } from 'zod';
import { MessageType } from '@fluidframework/driver-definitions/internal';
import type { IDocumentSystemMessage, ISequencedDocumentMessage } from '@fluidframework/driver-definitions/internal';
import { LocalContext, LocalOrderer, PubSub } from '@fluidframework/server-memory-orderer';
import type { IKafkaSubscriber } from '@fluidframework/server-memory-orderer';
import {
  CheckpointService,
  DefaultServiceConfiguration,
  MongoCheckpointRepository,
  MongoDatabaseManager,
  MongoDocumentRepository,
  MongoManager,
  RawOperationType,
  SequencedOperationType,
  extractBoxcar,
} from '@fluidframework/server-services-core';
import type { ILogger, IQueuedMessage, IRawOperationMessage, IServiceConfiguration } from '@fluidframework/server-services-core';
import { TestDbFactory, TestDocumentStorage, TestTenantManager } from '@fluidframework/server-test-utils';
import { LogLevel, Lumberjack } from '@fluidframework/server-services-telemetry';
import type { ILumberjackEngine, Lumber } from '@fluidframework/server-services-telemetry';
import type { OdspFile } from './store.js';

/** Server-side failures (lambda errors, contract violations). Every harness checkpoint requires it empty. */
export const serverFailures: string[] = [];

class FailureEngine implements ILumberjackEngine {
  emit(lumber: Lumber<string>): void {
    if (lumber.logLevel === LogLevel.Error) {
      serverFailures.push(`lumberjack: ${lumber.message ?? ''} ${lumber.exception?.stack ?? ''}`);
    }
  }
}

class FailureLogger implements ILogger {
  info(): void {}
  warn(): void {}
  error(message: string): void {
    serverFailures.push(`orderer: ${message}`);
  }
}

if (!Lumberjack.isSetupCompleted()) {
  Lumberjack.setup([new FailureEngine()]);
}

/**
 * ODSP push differences from the routerlicious defaults:
 * - no server traces on ops (push does not stamp them);
 * - deli does not attach its checkpoint as `additionalContent` to single-commit summarize ops,
 *   because no scribe consumes it (`includesProtocolTree` is set by container.ts for ODSP).
 */
export const serviceConfiguration: Partial<IServiceConfiguration> = {
  enableTraces: false,
  deli: {
    ...DefaultServiceConfiguration.deli,
    skipSummarizeAugmentationForSingleCommmit: true,
  },
};

/** driver-definitions ISequencedDocumentMessage; unknown keys are kept, the op is stored as sequenced. */
const sequencedOpSchema = z.looseObject({
  clientId: z.string().nullable(),
  sequenceNumber: z.number().int(),
  minimumSequenceNumber: z.number().int(),
  clientSequenceNumber: z.number().int(),
  referenceSequenceNumber: z.number().int(),
  type: z.string(),
  // Noops are sequenced with undefined contents (absent once serialized).
  contents: z.unknown().optional(),
  timestamp: z.number(),
});
const sequencedMessageSchema = z.object({ documentId: z.string(), operation: sequencedOpSchema });

const summaryContentSchema = z.object({
  handle: z.string(),
  head: z.string(),
  message: z.string(),
  parents: z.array(z.string()),
});

/** One document session: the real orderer plus the ODSP storage lambda. */
export class OdspSession {
  private constructor(
    readonly file: OdspFile,
    readonly tenantId: string,
    readonly orderer: LocalOrderer,
    readonly pubSub: PubSub,
  ) {}

  static async create(file: OdspFile, tenantId: string, pubSub: PubSub): Promise<OdspSession> {
    const dbFactory = new TestDbFactory({});
    const mongoManager = new MongoManager(dbFactory);
    const databaseManager = new MongoDatabaseManager(false, mongoManager, mongoManager, 'nodes', 'documents', 'checkpoints', 'deltas', 'scribeDeltas');
    const storage = new TestDocumentStorage(databaseManager, new TestTenantManager(undefined, undefined, dbFactory.testDatabase));
    const documentRepository = new MongoDocumentRepository(await databaseManager.getDocumentCollection());
    const deliCheckpointRepository = new MongoCheckpointRepository(await databaseManager.getCheckpointCollection(), 'deli');
    const scribeCheckpointRepository = new MongoCheckpointRepository(await databaseManager.getCheckpointCollection(), 'scribe');
    const orderer = await LocalOrderer.load(
      storage,
      databaseManager,
      tenantId,
      file.documentId,
      new FailureLogger(),
      documentRepository,
      deliCheckpointRepository,
      scribeCheckpointRepository,
      new CheckpointService(deliCheckpointRepository, documentRepository, false),
      new CheckpointService(scribeCheckpointRepository, documentRepository, false),
      undefined /* gitManager: no scribe, ODSP acks summaries below */,
      undefined /* setup */,
      pubSub,
      new LocalContext(new FailureLogger()),
      new LocalContext(new FailureLogger()),
      new LocalContext(new FailureLogger()),
      new LocalContext(new FailureLogger()),
      new LocalContext(new FailureLogger()),
      serviceConfiguration,
    );
    const session = new OdspSession(file, tenantId, orderer, pubSub);
    orderer.deltasKafka.subscribe(session.storageLambda);
    return session;
  }

  /** `flush_ops` requests waiting for persistence of everything sequenced when they arrived. */
  private readonly flushWaiters: { sequenceNumber: number; resolve: (persisted: number) => void }[] = [];
  /** Highest sequence number deli has assigned, as seen on the deltas stream. */
  lastSequenceNumber = 0;

  private readonly storageLambda: IKafkaSubscriber = {
    context: new LocalContext(new FailureLogger()),
    process: (message: IQueuedMessage) => {
      try {
        this.storeSequenced(message);
      } catch (error) {
        serverFailures.push(`storage lambda: ${error instanceof Error ? error.stack : String(error)}`);
      }
      return undefined;
    },
  };

  private storeSequenced(message: IQueuedMessage): void {
    const boxcar = extractBoxcar(message);
    for (const base of boxcar.contents) {
      if (base.type !== SequencedOperationType) {
        continue;
      }
      const sequenced = sequencedMessageSchema.parse(base);
      if (sequenced.documentId !== this.file.documentId) {
        continue;
      }
      const op: ISequencedDocumentMessage = { ...sequenced.operation, contents: sequenced.operation.contents };
      this.file.persistOp(op);
      this.lastSequenceNumber = op.sequenceNumber;
      if (op.type === MessageType.Summarize) {
        this.handleSummarize(op);
      }
    }
    this.releaseFlushes();
  }

  /** flush_ops: resolves with the last persisted sequence number once everything sequenced so far is persisted. */
  async flush(): Promise<number> {
    const target = this.lastSequenceNumber;
    if (this.file.lastPersistedSequenceNumber >= target) {
      return this.file.lastPersistedSequenceNumber;
    }
    return new Promise<number>(resolve => {
      this.flushWaiters.push({ sequenceNumber: target, resolve });
    });
  }

  private releaseFlushes(): void {
    const persisted = this.file.lastPersistedSequenceNumber;
    const pending = this.flushWaiters.splice(0);
    for (const waiter of pending) {
      if (persisted >= waiter.sequenceNumber) {
        waiter.resolve(persisted);
      } else {
        this.flushWaiters.push(waiter);
      }
    }
  }

  /**
   * Single-commit summary acknowledgement. The upload (POST snapshot) created a proposal whose
   * parent is the If-Match container id; the summarize op names that proposal (`handle`) and its
   * parent (`head`). The proposal is committed as latest when both still match, and acked with the
   * proposal id as the new ack handle; otherwise it is nacked. Mirrors scribe's sendSummaryAck/Nack.
   */
  private handleSummarize(op: ISequencedDocumentMessage): void {
    const content = summaryContentSchema.parse(JSON.parse(z.string().parse(op.contents)));
    const proposal = this.file.proposals.get(content.handle);
    const summaryProposal = { summarySequenceNumber: op.sequenceNumber };
    if (proposal === undefined) {
      this.sendToDeli(MessageType.SummaryNack, { message: `Unknown summary handle ${content.handle}`, summaryProposal });
      return;
    }
    this.file.proposals.delete(content.handle);
    if (proposal.parentId !== this.file.latestId || content.head !== this.file.latestId) {
      this.sendToDeli(MessageType.SummaryNack, { message: `Summary parent ${content.head} is not the latest ${this.file.latestId}`, summaryProposal });
      return;
    }
    this.file.snapshots.set(proposal.snapshot.id, proposal.snapshot);
    this.file.latestId = proposal.snapshot.id;
    this.sendToDeli(MessageType.SummaryAck, { handle: proposal.snapshot.id, summaryProposal });
  }

  /** scribe/utils.ts sendToDeli: a server message (clientId null) with JSON `data`. */
  private sendToDeli(type: MessageType.SummaryAck | MessageType.SummaryNack, contents: object): void {
    const operation: IDocumentSystemMessage = {
      clientSequenceNumber: -1,
      contents,
      data: JSON.stringify(contents),
      referenceSequenceNumber: -1,
      type,
    };
    const message: IRawOperationMessage = {
      clientId: null,
      documentId: this.file.documentId,
      operation,
      tenantId: this.tenantId,
      timestamp: Date.now(),
      type: RawOperationType,
    };
    this.orderer.rawDeltasKafka.send([message], this.tenantId).catch((error: unknown) => {
      serverFailures.push(`summary ${type} send failed: ${String(error)}`);
    });
  }

  async close(): Promise<void> {
    await this.orderer.close();
  }
}
