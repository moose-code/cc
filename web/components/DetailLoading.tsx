"use client";

import { useParams } from "next/navigation";
import { ArtFrame, Breadcrumb, RegMark } from "./Shell";
import { SkFacts, SkHistory } from "./Detail";
import { LoadingNote, Sk, SkSideSec } from "./Skeleton";

// The detail layout while a detail route loads (app/credits/[id]/loading.tsx, app/statements/[id]/loading.tsx): the
// breadcrumb and id are real, the art, facts, history and rail are skeletons in their final places, so the page that
// replaces it does not move.
export function DetailLoading({ kind }: { kind: "credit" | "statement" }) {
  const raw = useParams<{ id: string }>()?.id;
  const id = raw != null && /^\d+$/.test(raw) ? Number(raw) : undefined;
  const parent = kind === "credit" ? "credits" : "statements";
  const keys =
    kind === "credit"
      ? ["credit rating", "plates", "holder", "paid by engine", "got by", "acquired", "transaction id"]
      : ["credit rating", "format", "engine cost", "credits", "composed", "holder"];
  return (
    <div className="detail-page" aria-busy="true">
      <LoadingNote what={`loading ${kind}`} />
      <Breadcrumb parent={parent} parentHref={`/${parent}`} id={id ?? ""} />
      <div className="detail-split">
        <div className="detail-body">
          <div className="detail-left">
            <div className="hero-art">
              <ArtFrame crop="lg">
                <Sk block w="100%" className="sk-art sk-art-frame" />
              </ArtFrame>
            </div>
            <div className="hero-links">
              <span className="hero-dl">
                <Sk w="5ch" />
                <Sk w="8ch" />
              </span>
              <RegMark />
            </div>
          </div>
          <div className="detail-right">
            <div className="label">{kind}</div>
            <h1 className="detail-id">{id != null ? (kind === "credit" ? `#${id}` : id) : <Sk w="4ch" />}</h1>
            <SkFacts keys={keys} />
            <SkHistory n={2} />
          </div>
        </div>
        <aside className="side">
          <section className="side-sec">
            <div className="label">status</div>
            <div className="status-line">
              <Sk w="12ch" />
            </div>
          </section>
          <SkSideSec label="price" lines={0} kv={2} action />
        </aside>
      </div>
    </div>
  );
}
