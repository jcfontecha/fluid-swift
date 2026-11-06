// The local ODSP service: SharePoint REST (rest.ts) and push Socket.IO (push.ts) on one HTTP port,
// with ordering by the real Fluid server lambdas (ordering.ts). Clients reach it exactly like
// SharePoint Embedded: `siteUrl` is the origin, the API root is `<origin>/_api/v2.1`, and join
// session returns the push URL. Endpoint URLs follow the Host header, so a device can use a LAN
// address.
import { createServer, type Server as HttpServer } from 'node:http';
import { Server } from 'socket.io';
import { PubSub } from '@fluidframework/server-memory-orderer';
import { OdspDrive, type OdspFile } from './store.js';
import { OdspSession, serverFailures } from './ordering.js';
import { OdspPush } from './push.js';
import { OdspRest } from './rest.js';

/** base64url("local-odsp"): SharePoint Embedded drive ids are `b!` plus base64url. */
export const driveId = 'b!bG9jYWwtb2RzcA';
/** The relay tenant join session reports; push and the orderer key documents by it. */
export const tenantId = 'local-odsp';

export interface ConnectionInfo {
  readonly siteUrl: string;
  readonly driveId: string;
  readonly apiRoot: string;
}

export class OdspLocalService {
  readonly drive = new OdspDrive(driveId);
  readonly failures = serverFailures;
  private readonly sessions = new Map<string, OdspSession>();
  private readonly pubSub = new PubSub();
  readonly rest: OdspRest;
  readonly push: OdspPush;

  private constructor(
    private readonly http: HttpServer,
    private readonly io: Server,
    readonly port: number,
  ) {
    this.rest = new OdspRest({
      drive: this.drive,
      tenantId,
      session: file => this.session(file),
      createSession: file => this.createSession(file),
    });
    this.push = new OdspPush(io, (tenant, documentId) => this.sessionByDocument(tenant, documentId));
    http.on('request', (request, response) => {
      if (request.url?.startsWith('/socket.io/') === true) {
        return;
      }
      this.rest.handle(request, response).catch((error: unknown) => {
        serverFailures.push(`rest: ${error instanceof Error ? error.stack : String(error)}`);
      });
    });
  }

  static async start(port: number, host = '0.0.0.0'): Promise<OdspLocalService> {
    const http = createServer();
    // The driver connects websocket-only with reconnection disabled (odspDocumentDeltaConnection.ts).
    const io = new Server(http, { transports: ['websocket'], maxHttpBufferSize: 1e8 });
    const service = new OdspLocalService(http, io, port);
    await new Promise<void>((resolve, reject) => {
      http.once('error', reject);
      http.listen(port, host, () => resolve());
    });
    return service;
  }

  /** What a client needs (odsp-client OdspConnectionConfig): the origin is the site URL. */
  connectionInfo(hostname = 'localhost'): ConnectionInfo {
    const origin = `http://${hostname}:${this.port}`;
    return { siteUrl: origin, driveId, apiRoot: `${origin}/_api/v2.1` };
  }

  file(itemId: string): OdspFile {
    return this.drive.file(itemId);
  }

  session(file: OdspFile): OdspSession {
    const session = this.sessions.get(file.itemId);
    if (session === undefined) {
      throw new Error(`no session for ${file.itemId}`);
    }
    return session;
  }

  private async createSession(file: OdspFile): Promise<OdspSession> {
    const session = await OdspSession.create(file, tenantId, this.pubSub);
    this.sessions.set(file.itemId, session);
    return session;
  }

  private sessionByDocument(tenant: string, documentId: string): OdspSession | undefined {
    if (tenant !== tenantId) {
      return undefined;
    }
    for (const session of this.sessions.values()) {
      if (session.file.documentId === documentId) {
        return session;
      }
    }
    return undefined;
  }

  async close(): Promise<void> {
    this.io.disconnectSockets(true);
    await new Promise<void>(resolve => {
      this.io.close(() => resolve());
    });
    for (const session of this.sessions.values()) {
      await session.close();
    }
    this.sessions.clear();
  }
}
