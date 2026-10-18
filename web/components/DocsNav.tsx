"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { useEffect, useRef, useState } from "react";
import { docGroups, docHref, docPages, entryId } from "@/lib/docs-content";
import { contractCatalog } from "@/lib/docs-catalog";

type Result = { href: string; title: string; context: string };

export function DocsNav() {
  const path = usePathname();
  const [query, setQuery] = useState("");
  const [open, setOpen] = useState(false);
  const input = useRef<HTMLInputElement>(null);

  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "k") {
        event.preventDefault();
        setOpen(true);
        requestAnimationFrame(() => input.current?.focus());
      }
      if (event.key === "Escape") {
        setQuery("");
        input.current?.blur();
        setOpen(false);
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);

  useEffect(() => setOpen(false), [path]);

  const q = query.trim().toLowerCase();
  const results: Result[] = q
    ? docPages.flatMap((page) => {
        const href = docHref(page);
        const matches: Result[] = [];
        if (`${page.title} ${page.summary} ${page.eyebrow}`.toLowerCase().includes(q)) {
          matches.push({ href, title: page.title, context: page.group });
        }
        for (const section of page.sections) {
          if (`${section.title} ${section.intro ?? ""} ${(section.points ?? []).join(" ")}`.toLowerCase().includes(q)) {
            matches.push({ href: `${href}#${section.id}`, title: section.title, context: page.title });
          }
          section.entries?.forEach((entry, index) => {
            if (`${entry.signature} ${entry.description} ${entry.detail ?? ""} ${entry.errors ?? ""}`.toLowerCase().includes(q)) {
              matches.push({ href: `${href}#${entryId(section, index)}`, title: entry.signature, context: page.title });
            }
          });
        }
        const catalog = contractCatalog[page.slug as keyof typeof contractCatalog];
        catalog?.forEach((source, fileIndex) => source.declarations.forEach((entry, index) => {
          if (entry.signature.toLowerCase().includes(q)) {
            matches.push({ href: `${href}#catalog-${fileIndex + 1}-${index + 1}`, title: entry.signature, context: `${page.title} · complete interface` });
          }
        }));
        return matches;
      }).slice(0, 24)
    : [];

  return (
    <>
      <button className="docs-mobile-toggle" type="button" onClick={() => setOpen((value) => !value)} aria-expanded={open} aria-controls="docs-sidebar">
        <span>Browse documentation</span><span aria-hidden>{open ? "−" : "+"}</span>
      </button>
      <aside id="docs-sidebar" className={`docs-sidebar${open ? " is-open" : ""}`}>
        <div className="docs-sidebar-top">
          <Link href="/docs" className="docs-sidebar-brand" onClick={() => setOpen(false)}>
            <span className="docs-brand-mark" aria-hidden>▦</span>
            <span>CC docs</span>
            <span className="docs-sidebar-version">v1</span>
          </Link>
          <div className="docs-search-wrap">
            <span className="docs-search-icon" aria-hidden>⌕</span>
            <input
              ref={input}
              className="docs-search"
              type="search"
              placeholder="Search docs..."
              aria-label="Search documentation"
              value={query}
              onChange={(event) => setQuery(event.target.value)}
            />
            {!q && <kbd>⌘ K</kbd>}
          </div>
        </div>

        <nav className="docs-sidebar-scroll" aria-label="Documentation">
          {q ? (
            <div className="docs-results" aria-live="polite">
              <p className="docs-nav-label">{results.length ? `${results.length} results` : "No results"}</p>
              {results.map((result) => (
                <Link key={`${result.href}-${result.title}`} href={result.href} onClick={() => { setQuery(""); setOpen(false); }} className="docs-result">
                  <span>{result.title}</span>
                  <small>{result.context}</small>
                </Link>
              ))}
            </div>
          ) : docGroups.map((group) => (
            <div className="docs-nav-group" key={group}>
              <p className="docs-nav-label">{group}</p>
              {docPages.filter((page) => page.group === group).map((page) => {
                const href = docHref(page);
                const active = path === href;
                return (
                  <div key={href}>
                    <Link href={href} className={`docs-nav-link${active ? " is-active" : ""}`} onClick={() => setOpen(false)} aria-current={active ? "page" : undefined}>
                      <span>{page.title}</span><span className="docs-nav-chevron" aria-hidden>›</span>
                    </Link>
                    {active && page.sections.length > 0 && (
                      <div className="docs-nav-subsections">
                        {page.sections.map((section) => <a key={section.id} href={`#${section.id}`} onClick={() => setOpen(false)}>{section.title}</a>)}
                        {page.group === "Contract API" && <a href="#full-interface" onClick={() => setOpen(false)}>Complete interface</a>}
                      </div>
                    )}
                  </div>
                );
              })}
            </div>
          ))}
        </nav>
        <div className="docs-sidebar-bottom">Contract reference · main</div>
      </aside>
    </>
  );
}
