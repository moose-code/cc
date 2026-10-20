import type { Hex } from "viem";
import { CREDITS } from "@cc/engine/addresses";

const TOPIC = "collection:credits";
const EVENTS = ["item_listed", "item_sold", "item_transferred", "item_cancelled", "order_invalidate", "order_revalidate"];
const BACKOFF = [1_000, 2_000, 5_000, 10_000, 30_000];
const UINT256 = (1n << 256n) - 1n;

export type MarketChange = { event: string; hash?: Hex; id?: bigint; price?: bigint };
type Options = {
  key: string;
  onChange(change: MarketChange): void | Promise<void>;
  onGap(): void | Promise<void>;
  onStatus(joined: boolean): void | Promise<void>;
};

// Stream payloads only invalidate cached reads; the current canonical order remains authoritative.
function changeOf(event: string, envelope: any): MarketChange | null | undefined {
  if (!EVENTS.includes(event)) return EVENTS.includes(envelope?.event_type) ? null : undefined;
  const p = envelope?.payload;
  // Positively foreign events are ignored; malformed potential changes require reconciliation.
  if (typeof p?.collection?.slug === "string" && p.collection.slug !== "credits") return;
  const chain = typeof p?.chain === "string" ? p.chain : p?.chain?.name;
  if (typeof chain === "string" && chain !== "ethereum") return;
  if (typeof p?.item?.chain?.name === "string" && p.item.chain.name !== "ethereum") return;
  let id: bigint | undefined;
  if (p?.item?.nft_id != null) {
    if (typeof p.item.nft_id !== "string") return null;
    const parts = p.item.nft_id.split("/");
    if (parts.length !== 3) return null;
    if (!/^[a-z][a-z0-9_-]*$/.test(parts[0])) return null;
    if (parts[0] !== "ethereum") return chain === "ethereum" ? null : undefined;
    if (!/^0x[0-9a-f]{40}$/i.test(parts[1])) return null;
    if (parts[1].toLowerCase() !== CREDITS.toLowerCase()) return;
    if (!/^(0|[1-9][0-9]{0,77})$/.test(parts[2])) return null;
    id = BigInt(parts[2]);
    if (id > UINT256) return null;
  }
  if (envelope?.event_type !== event || p?.collection?.slug !== "credits") return null;
  const hash = typeof p.order_hash === "string" && /^0x[0-9a-f]{64}$/i.test(p.order_hash) ? p.order_hash.toLowerCase() as Hex : undefined;
  if (p.order_hash != null && hash == null) return null;
  if (id == null && (hash == null || chain !== "ethereum")) return null;
  // This untrusted lower bound only prioritizes canonical reads, never purchase amounts.
  let price: bigint | undefined;
  if (event === "item_listed" && p.payment_token?.address === "0x0000000000000000000000000000000000000000" &&
      p.payment_token.decimals === 18 && (p.quantity === 1 || p.quantity === "1") && p.is_private === false &&
      typeof p.base_price === "string" && /^[1-9][0-9]{0,77}$/.test(p.base_price)) {
    const hint = BigInt(p.base_price);
    if (hint <= UINT256) price = hint;
  }
  return { event, ...(hash ? { hash } : {}), ...(id != null ? { id } : {}), ...(price != null ? { price } : {}) };
}

export function startOpenSeaStream(options: Options): { stop(): void; ready: Promise<boolean> } {
  let socket: WebSocket | undefined;
  let stopped = false;
  let joined = false;
  let failures = 0;
  let attemptTimer: ReturnType<typeof setTimeout> | undefined;
  let heartbeatTimer: ReturnType<typeof setTimeout> | undefined;
  let reconnectTimer: ReturnType<typeof setTimeout> | undefined;
  let resolveReady: ((joined: boolean) => void) | undefined;
  const ready = new Promise<boolean>((resolve) => { resolveReady = resolve; });
  const finishReady = (value: boolean) => { resolveReady?.(value); resolveReady = undefined; clearTimeout(readyTimer); };
  const readyTimer = setTimeout(() => finishReady(false), 10_000);
  const call = (fn: () => void | Promise<void>, failed = () => {}) => { try { void Promise.resolve(fn()).catch(failed); } catch { failed(); } };

  const disconnect = (current: WebSocket) => {
    if (socket !== current || stopped) return;
    socket = undefined;
    clearTimeout(attemptTimer);
    clearTimeout(heartbeatTimer);
    joined = false;
    call(() => options.onStatus(false));
    if (!stopped) call(() => options.onGap());
    try { current.close(); } catch {}
    if (!stopped) reconnectTimer = setTimeout(connect, BACKOFF[Math.min(failures++, BACKOFF.length - 1)]);
  };

  const connect = () => {
    if (stopped) return;
    let current: WebSocket;
    try {
      current = new WebSocket("wss://stream-api.opensea.io/socket/websocket?token=" + encodeURIComponent(options.key) + "&vsn=2.0.0");
    } catch {
      call(() => options.onStatus(false));
      if (!stopped) call(() => options.onGap());
      if (!stopped) reconnectTimer = setTimeout(connect, BACKOFF[Math.min(failures++, BACKOFF.length - 1)]);
      return;
    }
    socket = current;
    const gap = () => { if (!stopped && socket === current && joined) call(() => options.onGap()); };
    let pendingHeartbeat: string | undefined;
    let ref = 1;
    const send = (frame: unknown[]) => {
      try { current.send(JSON.stringify(frame)); return true; }
      catch { disconnect(current); return false; }
    };
    const heartbeat = () => {
      if (socket !== current || !joined || stopped) return;
      if (pendingHeartbeat != null) { disconnect(current); return; }
      pendingHeartbeat = String(++ref);
      if (send([null, pendingHeartbeat, "phoenix", "heartbeat", {}])) heartbeatTimer = setTimeout(heartbeat, 30_000);
    };
    attemptTimer = setTimeout(() => disconnect(current), 10_000);
    current.addEventListener("open", () => {
      if (socket === current && !stopped) send(["1", "1", TOPIC, "phx_join", { event_types: EVENTS }]);
    });
    current.addEventListener("message", (message) => {
      if (socket !== current || stopped) return;
      if (typeof message.data !== "string") { gap(); return; }
      if (Buffer.byteLength(message.data) > 1_048_576) { disconnect(current); return; }
      let frame: any;
      try { frame = JSON.parse(message.data); } catch { gap(); return; }
      if (!Array.isArray(frame) || frame.length !== 5) {
        if (!Array.isArray(frame) || typeof frame[2] !== "string" || frame[2] === TOPIC) gap();
        return;
      }
      const [joinRef, replyRef, topic, event, payload] = frame;
      if (topic === "phoenix" && event === "phx_reply" && replyRef === pendingHeartbeat && pendingHeartbeat != null) {
        if (payload?.status !== "ok") { disconnect(current); return; }
        pendingHeartbeat = undefined;
        return;
      }
      if (topic !== TOPIC || joinRef !== "1") return;
      if (event === "phx_reply" && replyRef === "1") {
        if (payload?.status !== "ok") { disconnect(current); return; }
        if (joined) return;
        clearTimeout(attemptTimer);
        joined = true;
        failures = 0;
        finishReady(true);
        call(() => options.onGap());
        if (stopped || socket !== current) return;
        call(() => options.onStatus(true));
        if (!stopped && socket === current) heartbeatTimer = setTimeout(heartbeat, 30_000);
        return;
      }
      if (event === "phx_error" || event === "phx_close") { disconnect(current); return; }
      if (!joined) return;
      if (typeof event !== "string") { gap(); return; }
      const change = changeOf(event, payload);
      if (change === null) gap();
      else if (change) call(() => options.onChange(change), gap);
    });
    current.addEventListener("error", () => disconnect(current));
    current.addEventListener("close", () => disconnect(current));
  };
  connect();
  return {
    ready,
    stop() {
      if (stopped) return;
      stopped = true;
      clearTimeout(attemptTimer);
      clearTimeout(heartbeatTimer);
      clearTimeout(reconnectTimer);
      finishReady(false);
      const current = socket;
      socket = undefined;
      if (joined) call(() => options.onStatus(false));
      joined = false;
      try { current?.close(); } catch {}
    },
  };
}
