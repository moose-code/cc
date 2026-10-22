import Link from "next/link";
import { docHref, docPages, entryId, type DocPage } from "@/lib/docs-content";
import { contractCatalog } from "@/lib/docs-catalog";

const sourceBase = "https://github.com/ripe0x/cc/blob/";
const sourceRevision = "0dba672d899b5aeddcfb85b1f535d67ba3ad8d4f";

export function DocsPage({ page }: { page: DocPage }) {
  const index = docPages.indexOf(page);
  const prev = docPages[index - 1];
  const next = docPages[index + 1];
  const catalog = contractCatalog[page.slug as keyof typeof contractCatalog];

  return (
    <div className="docs-page-grid">
      <article className="docs-article">
        <div className="docs-breadcrumb"><Link href="/docs">Docs</Link><span>/</span><span>{page.group}</span></div>
        <header className="docs-article-head">
          <span className="docs-eyebrow">{page.eyebrow}</span>
          <h1>{page.title}</h1>
          <p>{page.summary}</p>
          {page.mainnetAddress && (
            <div className="docs-source">
              <span>Ethereum mainnet</span>
              <a href={`https://etherscan.io/address/${page.mainnetAddress}`} target="_blank" rel="noreferrer">{page.mainnetAddress} ↗</a>
            </div>
          )}
          {page.mainnetAddresses?.map(({ label, address }) => (
            <div className="docs-source" key={address}>
              <span>{label} · Ethereum mainnet</span>
              <a href={`https://etherscan.io/address/${address}`} target="_blank" rel="noreferrer">{address} ↗</a>
            </div>
          ))}
          {page.source && (
            <div className="docs-source">
              <span>Source interface</span>
              <a href={`${sourceBase}${page.sourceRevision ?? sourceRevision}/${page.source}`} target="_blank" rel="noreferrer">{page.source} ↗</a>
            </div>
          )}
        </header>

        {page.slug === "" && (
          <div className="docs-quick-grid">
            {docPages.filter((item) => item.group === "Contracts").map((item, i) => (
              <Link href={docHref(item)} key={item.slug} className="docs-quick-card">
                <span className={`docs-quick-icon docs-quick-icon-${i % 4}`} aria-hidden="true" />
                <strong>{item.title}</strong>
                <span>{item.summary}</span>
                <b>View reference →</b>
              </Link>
            ))}
          </div>
        )}

        {page.sections.map((section) => (
          <section className="docs-section" id={section.id} key={section.id}>
            <div className="docs-section-head"><span className="docs-section-rule" /><h2>{section.title}</h2></div>
            {section.intro && <p className="docs-section-intro">{section.intro}</p>}
            {section.points && (
              <div className="docs-points">
                {section.points.map((point, index) => (
                  <div className="docs-point" key={point}>
                    <span className="docs-point-index">{String(index + 1).padStart(2, "0")}</span>
                    <p>{point}</p>
                  </div>
                ))}
              </div>
            )}
            {section.entries && (
              <div className="docs-entry-list">
                {section.entries.map((entry, index) => (
                  <div className="docs-entry" id={entryId(section, index)} key={`${entry.signature}-${index}`}>
                    <div className="docs-entry-top">
                      <code>{entry.signature}</code>
                      {entry.access && <span className="docs-entry-access">{entry.access}</span>}
                    </div>
                    <p>{entry.description}</p>
                    {entry.detail && <p>{entry.detail}</p>}
                    {entry.errors && <p className="docs-entry-errors"><b>May revert:</b> {entry.errors}</p>}
                  </div>
                ))}
              </div>
            )}
          </section>
        ))}

        {catalog && (
          <section className="docs-section docs-catalog" id="full-interface">
            <div className="docs-section-head"><span className="docs-section-rule" /><h2>Complete interface</h2></div>
            <p className="docs-section-intro">Functions, events, and errors from the generated interfaces.</p>
            {catalog.map((source, fileIndex) => (
              <div className="docs-catalog-source" key={source.file}>
                <h3>{source.file}</h3>
                {(["function", "event", "error"] as const).map((kind) => {
                  const entries = source.declarations.map((entry, index) => ({ entry, index })).filter(({ entry }) => entry.kind === kind);
                  if (!entries.length) return null;
                  return (
                    <div className="docs-catalog-group" key={kind}>
                      <h4>{kind === "function" ? "Functions" : kind === "event" ? "Events" : "Errors"} <span>{entries.length}</span></h4>
                      {entries.map(({ entry, index }) => (
                        <div className="docs-catalog-row" id={`catalog-${fileIndex + 1}-${index + 1}`} key={index}>
                          <code>{entry.signature}</code>
                        </div>
                      ))}
                    </div>
                  );
                })}
              </div>
            ))}
          </section>
        )}

        <div className="docs-page-footer">
          {prev ? <Link href={docHref(prev)} className="docs-page-turn"><small>← Previous</small><strong>{prev.title}</strong></Link> : <span />}
          {next && <Link href={docHref(next)} className="docs-page-turn is-next"><small>Next →</small><strong>{next.title}</strong></Link>}
        </div>
      </article>
      <aside className="docs-toc" aria-label="On this page">
        <p>On this page</p>
        {page.sections.map((section) => <a key={section.id} href={`#${section.id}`}>{section.title}</a>)}
        {catalog && <a href="#full-interface">Complete interface</a>}
      </aside>
    </div>
  );
}
