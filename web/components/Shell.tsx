import Link from "next/link";
import type { CSSProperties, ReactNode } from "react";
import { Sk } from "./Skeleton";

// Page head band: title, meta line and a right slot for toggles and sort.
// `ink` sets the 3px top edge (credits m, statements y). The meta line is always there: until the page passes it
// (meta undefined while its data loads) it is a skeleton of `metaW`, so the band keeps its height. On a phone a long
// meta wraps: `metaLines` is the lines it takes there, reserved loaded or not, since its figures arrive one by one.
export function PageHead({
  title,
  meta,
  metaW = "36ch",
  metaLines = 1,
  ink,
  children,
}: {
  title: string;
  meta?: ReactNode;
  metaW?: string;
  metaLines?: number;
  ink?: "c" | "m" | "y" | "k";
  children?: ReactNode;
}) {
  return (
    <div className={`head-band${ink ? ` ink-${ink}` : ""}`}>
      <div className="head-band-main">
        <h1>{title}</h1>
        <div className="head-band-meta" style={{ "--meta-lines": metaLines } as CSSProperties}>
          {meta == null ? (
            <>
              <Sk w={metaW} />
              {Array.from({ length: metaLines - 1 }, (_, i) => (
                <Sk key={i} w={i === metaLines - 2 ? "55%" : "100%"} className="sk-wrap" />
              ))}
            </>
          ) : (
            <span className="fx-in">{meta}</span>
          )}
        </div>
      </div>
      {children && <div className="head-band-slot">{children}</div>}
    </div>
  );
}

// Detail breadcrumb: "← parent / #id" with prev and next links on the right.
export function Breadcrumb({
  parent,
  parentHref,
  id,
  prevHref,
  nextHref,
}: {
  parent: string;
  parentHref: string;
  id: string | number;
  prevHref?: string;
  nextHref?: string;
}) {
  return (
    <div className="crumb">
      <div>
        <Link href={parentHref}>← {parent}</Link> / <b>#{id}</b>
      </div>
      <div className="crumb-nav">
        {prevHref ? <Link href={prevHref}>← prev</Link> : <span>← prev</span>}
        {nextHref ? <Link href={nextHref}>next →</Link> : <span>next →</span>}
      </div>
    </div>
  );
}

// Decorative 16px circle-and-cross.
export function RegMark() {
  return (
    <svg className="reg-mark" width="16" height="16" viewBox="0 0 16 16" fill="none" aria-hidden>
      <circle cx="8" cy="8" r="5" stroke="currentColor" />
      <path d="M8 0v16M0 8h16" stroke="currentColor" />
    </svg>
  );
}

// Art on white with a hairline outline. `crop` adds corner crop marks
// (size classes: crop-lg 10px, crop-md 8px, crop-sm 6px).
export function ArtFrame({
  crop,
  children,
}: {
  crop?: "lg" | "md" | "sm";
  children: ReactNode;
}) {
  return (
    <div className={`art-frame${crop ? ` crop crop-${crop}` : ""}`}>
      {crop && (
        <>
          <i className="tl" />
          <i className="tr" />
          <i className="bl" />
          <i className="br" />
        </>
      )}
      {children}
    </div>
  );
}
