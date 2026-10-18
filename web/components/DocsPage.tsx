import Link from "next/link";
import { docHref, docPages, entryId, type DocPage } from "@/lib/docs-content";
import { contractCatalog } from "@/lib/docs-catalog";

const sourceBase = "https://github.com/ripe0x/cc/blob/a6099d2b54a0b41dadf477d92b9e6c99e3a2f1b0/";

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
          {page.source && (
            <div className="docs-source">
              <span>Source interface</span>
              <a href={`${sourceBase}${page.source}`} target="_blank" rel="noreferrer">{page.source} ↗</a>
            </div>
          )}
        </header>

        {page.slug === "" && (
          <div className="docs-quick-grid">
            {docPages.filter((item) => item.group === "Contract API").map((item, i) => (
              <Link href={docHref(item)} key={item.slug} className="docs-quick-card">
                <span className={`docs-quick-icon docs-quick-icon-${i}`}>{["C", "V", "B", "A"][i]}</span>
                <strong>{item.title}</strong>
                <span>{item.summary}</span>
                <b>Explore API →</b>
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
            <p className="docs-section-intro">Every function, event, and custom error declared by the generated interfaces at the source revision above. The entries above explain the main integration paths.</p>
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
        <div className="docs-toc-note">Reference follows the generated interfaces on main at <code>a6099d2</code>. Check live settings before sending a transaction.</div>
      </aside>
    </div>
  );
}
