// Every Gametime API v3 endpoint (docs/marketplace/gametime/), tagged by what
// it does to Gametime, plus the inventory file upload.
//
//   read     GET, changes nothing.
//   write    changes Gametime state (an order, a listing). Built, dry-run;
//            sending one needs an operator WriteAuthorization.
//   upload   the inventory CSV on Gametime's FTP server (gtftp.gametime.co).
//            Gametime treats each file as the account's inventory and turns
//            every listing off if none arrives for six hours, so it is only
//            ever sent for a Gametime account that holds nothing but Exos
//            listings: the authorization must say so (dedicatedAccount).
//
// Auth: the API key in the `source` query parameter (Gametime's scheme). It
// is redacted from every URL this code logs or plans.

export type Access = 'read' | 'write' | 'upload';
export type HttpMethod = 'GET' | 'POST' | 'DELETE';

export interface Endpoint {
  method: HttpMethod;
  path: string;
  access: Access;
}

const e = <A extends Access>(method: HttpMethod, path: string, access: A) => ({ method, path, access });

export const GAMETIME_API_HOSTS = {
  production: 'https://api.gametime.co/v3',
  staging: 'https://api-staging.gametime.co/v3',
} as const;
export const GAMETIME_FTP_HOSTS = { production: 'gtftp.gametime.co', staging: 'gtftp-staging.gametime.co' } as const;
export type GametimeEnvironment = keyof typeof GAMETIME_API_HOSTS;

export const GAMETIME_ENDPOINTS = {
  listPurchases: e('GET', '/purchases', 'read'),
  confirmPurchase: e('POST', '/purchases/{orderNumber}/confirm', 'write'),
  rejectPurchase: e('POST', '/purchases/{orderNumber}/reject', 'write'),
  uploadBarcodes: e('POST', '/purchases/{orderNumber}/barcode_upload', 'write'),
  confirmTransfer: e('POST', '/purchases/{orderNumber}/confirm_transfer', 'write'),
  uploadPdf: e('POST', '/purchases/{orderNumber}/pdf_upload', 'write'),
  editListing: e('POST', '/listings/{id}', 'write'),
  deleteListing: e('DELETE', '/listings/{id}/delete', 'write'),
  /** FTP, not HTTP: the whole-account inventory file. */
  uploadInventory: e('POST', 'ftp://{host}/inventory.csv', 'upload'),
} as const satisfies Record<string, Endpoint>;

export type EndpointName = keyof typeof GAMETIME_ENDPOINTS;

/** Fills `{name}` segments, URI-encoding each value. Throws on a missing one. */
export function buildPath(template: string, params: Record<string, string | number> = {}): string {
  return template.replace(/\{(\w+)\}/g, (_, key: string) => {
    const v = params[key];
    if (v === undefined || v === '') throw new Error(`gametime: missing path param "${key}" for ${template}`);
    return encodeURIComponent(String(v));
  });
}
