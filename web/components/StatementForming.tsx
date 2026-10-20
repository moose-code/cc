"use client";

import Link from "next/link";
import { CreditTile } from "./Tiles";
import { Act } from "./Act";
import { ArtFrame, Breadcrumb, RegMark } from "./Shell";
import { Fact, HistLine, SkFacts, SkHistory } from "./Detail";
import { Sk } from "./Skeleton";
import { FormingArt } from "./Cards";
import { useComposeEta } from "./ComposeEta";
import { core, STATEMENT_SIZE } from "@/lib/config";
import { coreAbi } from "@/lib/abis";
import { countdown, usePile, type PileCredit, type Snapshot } from "@/lib/live";
import { etaLabel, type Eta } from "@/lib/compose-eta";
import { formingAt, type FormingKind } from "@/lib/forming";
import { eth, rating } from "@/lib/format";

const KIND_LABEL: Record<FormingKind, string> = { building: "in progress", upcoming: "upcoming", ready: "ready to compose" };

// Detail of a statement id the Core has not minted yet (id >= nextStatementId): page k = id - nextStatementId of the
// pile, the credits default compose will take for it (web/lib/forming.ts). Full-size version of the /statements forming
// card. The page turns into the composed statement's detail once the Core mints this id.
export function FormingStatement({ id, snap, prevHref, nextHref }: { id: number; snap: Snapshot; prevHref?: string; nextHref?: string }) {
  const { data: pile, loading } = usePile();
  const eta = useComposeEta(pile);
  const size = STATEMENT_SIZE;
  const k = id - (snap.nextStatementId ?? id);
  const at = formingAt(k, { ids: pile.map((c) => c.id), pileSize: Number(snap.pileSize), size, nextSid: snap.nextStatementId, ready: snap.page.ready });
  const page = !loading && at.status === "forming" ? at.page : undefined;
  const credits: PileCredit[] = page ? pile.slice(k * size, k * size + page.ids.length) : [];
  const n = credits.length;
  const cost = credits.reduce((a, c) => a + c.cost, 0n);
  // the statement's rating is the sum of its credits' scores; scores are read in indexer mode only
  const score = n > 0 && credits.every((c) => c.score != null) ? credits.reduce((a, c) => a + (c.score ?? 0n), 0n) : undefined;
  const newest = credits.at(-1);
  const first = credits[0];

  return (
    <div className="detail-page">
      <Breadcrumb parent="statements" parentHref="/statements" id={id} prevHref={prevHref} nextHref={nextHref} />

      <div className="detail-split">
        <div className="detail-col">
          <div className="detail-body">
            <div className="detail-left">
              <div className="hero-art">
                <ArtFrame crop="lg">
                  <FormingArt ids={page?.ids ?? []} size={size} />
                </ArtFrame>
              </div>
              <div className="hero-links">
                <span className="hero-dl muted">{page ? "forming · art set at compose" : ""}</span>
                <RegMark />
              </div>
            </div>

            <div className="detail-right">
              <div className="label">statement</div>
              <h1 className="detail-id">{id}</h1>

              {loading && <SkFacts keys={["state", "credits", "engine cost", "credit rating", "format", "holder"]} />}
              {loading && <SkHistory n={3} />}
              {!loading && at.status === "unavailable" && <p className="side-copy">this page of the pile is unavailable until the full pile loads.</p>}
              {!loading && at.status === "empty" && <p className="side-copy">not forming yet. no Credit has reached this page of the pile.</p>}
              {page && (
                <>
                  <dl className="dfacts fx-in">
                    <Fact k="state" v={snap.paused ? `${KIND_LABEL[page.kind]} · engine paused` : KIND_LABEL[page.kind]} />
                    <Fact k="credits" v={`${n} / ${size}`} />
                    <Fact k="engine cost" v={`${eth(cost)} ETH so far`} />
                    <Fact k="credit rating" v={score != null ? `${rating(score)} so far` : "—"} />
                    <Fact k="format" v="set at compose" />
                    <Fact k="holder" v="not minted" />
                  </dl>
                  <section className="dhist">
                    <div className="label">history</div>
                    <div className="dhist-rows">
                      <HistLine mark="hollow" when="now" text={page.kind === "ready" ? "ready to compose" : `forming, ${n} of ${size} credits`} value="—" />
                      {newest && <BoughtLine c={newest} />}
                      {first && first !== newest && <BoughtLine c={first} first />}
                    </div>
                  </section>
                </>
              )}
            </div>
          </div>

          {page && n > 0 && (
            <section className="cband">
              <div className="cband-head">
                <span className="label">
                  {n} / {size} credits
                </span>
                <span className="caption">gathering in the order the engine bought them</span>
              </div>
              <div className="cband-grid">
                {credits.map((c) => (
                  <Link key={c.id} href={`/credits/${c.id}`} title={`credit #${c.id}`}>
                    <CreditTile id={c.id} />
                  </Link>
                ))}
              </div>
            </section>
          )}
        </div>

        <aside className="side ink-y">
          <section className="side-sec">
            <div className="label">status</div>
            <div className="status-line">
              <span className="mark hollow" />
              {page ? KIND_LABEL[page.kind] : loading ? <Sk w="12ch" /> : "not forming"}
            </div>
            {page && <p className="side-copy">{statusCopy(page.kind, k, id, size - n, snap.paused)}</p>}
            {!loading && at.status === "empty" && (
              <p className="side-copy">
                statements form 80 Credits at a time, oldest first. see the forming pages on <Link href="/statements">statements</Link>.
              </p>
            )}
          </section>

          {page && (
            <section className="side-sec">
              <ComposeWhen kind={page.kind} k={k} id={id} n={n} size={size} paused={snap.paused} e={eta.at(k * size)} />
              {page.kind === "ready" && k === 0 && !snap.paused && (
                <>
                  <div className="side-act">
                    <Act label="compose statement" steps={async (write) => void (await write({ address: core, abi: coreAbi, functionName: "compose" }))} />
                  </div>
                  <p className="caption">
                    random format. to pick one, use the <Link href="/compose">compose page</Link>.
                  </p>
                </>
              )}
            </section>
          )}

          {page && snap.creditSaleOn && (
            <section className="side-sec">
              <p className="caption">
                every Credit here is for sale until it composes. a Credit bought out of the pile leaves this page and the next oldest moves in
                {snap.chosenComposeOn ? "; chosen compose can also take Credits out of order." : "."}
              </p>
            </section>
          )}
        </aside>
      </div>
    </div>
  );
}

function statusCopy(kind: FormingKind, k: number, id: number, missing: number, paused: boolean): string {
  const base =
    kind === "building"
      ? `${missing} more ${missing === 1 ? "Credit completes" : "Credits complete"} this page. it composes once full and its newest Credit clears the sale window.`
      : kind === "ready"
        ? "the page is full and past the sale window. anyone can compose it."
        : k > 0
          ? `the page is full. it composes after statement ${id - 1}, once its newest Credit clears the sale window.`
          : "the page is full. it composes once its newest Credit clears the sale window.";
  return paused ? `${base} composition waits while the engine is paused.` : base;
}

// When the page composes: a countdown for a full page (its newest credit's window), an estimate for a filling page
// (the missing credits at the recent buy rate plus the window), the 8 x 10 map of filled slots.
function ComposeWhen({
  kind,
  k,
  id,
  n,
  size,
  paused,
  e,
}: {
  kind: FormingKind;
  k: number;
  id: number;
  n: number;
  size: number;
  paused: boolean;
  e: Eta | undefined;
}) {
  const big = paused
    ? "paused"
    : kind === "ready"
      ? "now"
      : e == null
        ? "—"
        : e.estimated
          ? etaLabel(e)
          : e.seconds > 0
            ? countdown(e.seconds)
            : k === 0
              ? "now"
              : "next";
  return (
    <div className="compose-box">
      <div>
        <div className="caption">composes in</div>
        <div className="compose-eta" suppressHydrationWarning>
          {big}
        </div>
        <div className="caption">
          {n} of {size} credits
          {e?.estimated && !paused && " · estimate"}
          {k > 0 && ` · after statement ${id - 1}`}
        </div>
      </div>
      <div className="mini-map" aria-hidden>
        {Array.from({ length: size }, (_, j) => (
          <i key={j} className={j < n ? "on" : ""} />
        ))}
      </div>
    </div>
  );
}

function BoughtLine({ c, first }: { c: PileCredit; first?: boolean }) {
  return (
    <HistLine
      mark="m"
      ts={c.acquiredAt}
      text={
        <>
          {first ? "first" : "newest"} <Link href={`/credits/${c.id}`}>credit #{c.id}</Link> bought
        </>
      }
      value={`${eth(c.cost)} ETH`}
    />
  );
}
