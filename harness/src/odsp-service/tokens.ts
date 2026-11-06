// Fake bearer tokens for the local ODSP service. They carry no secret, but the service checks that
// each one is presented where ODSP expects it: the storage token on every SharePoint REST call
// (`Authorization: Bearer storage:<user>`, as a header or inside the UMP body) and the push token in
// `connect_document.token` (`push:<user>`). Swapping them is rejected with 401.
import type { IUser } from '@fluidframework/driver-definitions';

/** The user identity push puts in the join op; odsp-client's createOdspAudienceMember reads oid/name/email. */
export interface OdspUser extends IUser {
  oid: string;
  name: string;
  email: string;
}

const userPattern = /^[A-Za-z0-9._-]+$/;

export function userFromToken(token: string, kind: 'storage' | 'push'): OdspUser | undefined {
  const prefix = `${kind}:`;
  if (!token.startsWith(prefix)) {
    return undefined;
  }
  const id = token.slice(prefix.length);
  if (!userPattern.test(id)) {
    return undefined;
  }
  return { id, oid: id, name: id, email: `${id}@local-odsp.test` };
}

export function storageToken(user: string): string {
  return `storage:${user}`;
}

export function pushToken(user: string): string {
  return `push:${user}`;
}
