"use client";

import type { ReactNode } from "react";
import { ArtFrame, RegMark } from "./Shell";
import { Sk } from "./Skeleton";
import { useBlockTs } from "@/lib/engine";
import { useNow } from "@/lib/live";
import { agoLabel, evmNowAddress } from "@/lib/format";

export type Ink = "c" | "m" | "y" | "k";

// Key and value row of the detail facts list.
export function Fact({ k, v }: { k: string; v: ReactNode }) {
  return (
    <div className="fact">
      <dt>{k}</dt>
      <dd>{v}</dd>
    </div>
  );
}

// History line: ink mark, text, value. The time is `when`, else the age of `ts` (unix seconds, indexer rows) or of `block` (chain scan rows).
export function HistLine({
  mark,
  text,
  value,
  when,
  ts,
  block,
}: {
  mark: Ink | "hollow";
  text: ReactNode;
  value: ReactNode;
  when?: string;
  ts?: number;
  block?: bigint;
}) {
  const now = useNow();
  const { data: blockTs } = useBlockTs(ts == null ? block : undefined);
  const at = ts ?? blockTs;
  return (
    <div className="hist-row">
      <span className="t" suppressHydrationWarning>
        {when ?? (at != null ? agoLabel(now - at) : "")}
      </span>
      <span className="what">
        <span className={`mark ${mark}`} />
        <span>{text}</span>
      </span>
      <span className="v">{value}</span>
    </div>
  );
}

// Detail hero: framed art, svg download when the token image is an svg data URI (its place held while `loading`),
// explorer link and registration mark.
export function HeroArt({
  tile,
  image,
  file,
  address,
  loading,
}: {
  tile: ReactNode;
  image?: string;
  file: string;
  address: string;
  loading?: boolean; // the metadata has not answered: hold the download link's place
}) {
  const svg = image?.startsWith("data:image/svg") ? image : undefined;
  return (
    <div className="detail-left">
      <div className="hero-art">
        <ArtFrame crop="lg">{tile}</ArtFrame>
      </div>
      <div className="hero-links">
        <span className="hero-dl">
          {svg ? (
            <a href={svg} download={file} className="fx-in">
              svg ↓
            </a>
          ) : (
            loading && <Sk w="5ch" />
          )}
          <a href={evmNowAddress(address)} target="_blank" rel="noreferrer" className="muted">
            evm.now ↗
          </a>
        </span>
        <RegMark />
      </div>
    </div>
  );
}

// Facts while the record loads: the real keys, each value a skeleton, so the list does not grow when it arrives.
export function SkFacts({ keys }: { keys: string[] }) {
  return (
    <dl className="dfacts" aria-busy="true">
      {keys.map((k, i) => (
        <Fact key={k} k={k} v={<Sk w={["8ch", "12ch", "10ch", "14ch"][i % 4]} />} />
      ))}
    </dl>
  );
}

// History while it loads: the label and `n` rows of the history's shape.
export function SkHistory({ n = 2 }: { n?: number }) {
  return (
    <section className="dhist" aria-busy="true">
      <div className="label">history</div>
      <div className="dhist-rows">
        {Array.from({ length: n }, (_, i) => (
          <div key={i} className="hist-row" aria-hidden>
            <span className="t">
              <Sk w="4ch" />
            </span>
            <span className="what">
              <Sk w={i % 2 ? "18ch" : "24ch"} />
            </span>
            <span className="v">
              <Sk w="6ch" />
            </span>
          </div>
        ))}
      </div>
    </section>
  );
}
