// types of opensea.mjs

export declare const CREDITS: string;
export declare const SEAPORT_16: string;
export declare const OPENSEA_FEE: string;

export declare class OpenSeaPending extends Error {
  retryAt: number;
  hash?: string;
  constructor(retryAt: number, hash?: string);
}

export interface MarketCandidate {
  id: string;
  price: string;
  hash: string;
  offerer: string;
  startTime: string;
  endTime: string;
}

export interface MarketBook {
  rows: Map<string, MarketCandidate>;
  signed: Map<string, SignedOrder>;
  complete: boolean;
  slug?: string;
  identity?: string;
  lastFullAt: number;
  apiNext: number;
}

export declare function createMarketBook(): MarketBook;

export declare class OpenSeaUnavailable extends Error {
  constructor();
}

export declare class OpenSeaRateLimit extends Error {
  retryAt: number;
  constructor(retryAt: number);
}

// BasicOrderParameters of Seaport 1.6, every number a decimal string
export interface BasicParams {
  considerationToken: string;
  considerationIdentifier: string;
  considerationAmount: string;
  offerer: string;
  zone: string;
  offerToken: string;
  offerIdentifier: string;
  offerAmount: string;
  basicOrderType: string;
  startTime: string;
  endTime: string;
  zoneHash: string;
  salt: string;
  offererConduitKey: string;
  fulfillerConduitKey: string;
  totalOriginalAdditionalRecipients: string;
  additionalRecipients: { amount: string; recipient: string }[];
  signature: string;
}

export interface SignedOrder {
  id: string;
  price: string;
  hash: string;
  params: BasicParams;
}

export interface FetchResult {
  fetched: number;
  mode: "full" | "incremental";
  bookSize: number;
  reusedParams: number;
  complete: boolean;
  pages: number;
  validationTruncated: boolean;
  fit: number;
  notHeld: number;
  orders: SignedOrder[];
  dropped: Record<string, number>;
}

export declare function fetchListings(o: {
  key: string;
  rpc?: string;
  rpcUrls?: string[];
  adapter?: string;
  pages?: number;
  fullScan?: boolean;
  book?: MarketBook;
  updates?: string[];
  removals?: string[];
  reconcile?: boolean;
  getScores?: (ids: string[]) => Promise<bigint[]>;
  sign?: number;
  fulfiller?: string;
  allowedRecipients?: string[];
  horizon?: number;
  timeoutMs?: number;
  fulfillmentTimeoutMs?: number;
  sleep?: (ms: number) => Promise<void>;
}): Promise<FetchResult>;

export declare function basicParams(p: any): BasicParams;
