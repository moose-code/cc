"use client";

import type { ReactNode } from "react";
import { ArtFrame, RegMark } from "./Shell";
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

// Detail hero: framed art, svg download when the token image is an svg data URI, explorer link and registration mark.
export function HeroArt({
  tile,
  image,
  file,
  address,
}: {
  tile: ReactNode;
  image?: string;
  file: string;
  address: string;
}) {
  const svg = image?.startsWith("data:image/svg") ? image : undefined;
  return (
    <div className="detail-left">
      <div className="hero-art">
        <ArtFrame crop="lg">{tile}</ArtFrame>
      </div>
      <div className="hero-links">
        <span className="hero-dl">
          {svg && (
            <a href={svg} download={file}>
              svg ↓
            </a>
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
