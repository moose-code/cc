import type { Metadata } from "next";
import { notFound, redirect } from "next/navigation";
import { DocsPage } from "@/components/DocsPage";
import { docPage, docPages } from "@/lib/docs-content";

export function generateStaticParams() {
  return [...docPages.filter((page) => page.slug).map((page) => ({ slug: page.slug.split("/") })),
    { slug: ["guides", "read"] }, { slug: ["guides", "write"] }, { slug: ["contracts", "balance-module"] }];
}

export function generateMetadata({ params }: { params: { slug: string[] } }): Metadata {
  const page = docPage(params.slug.join("/"));
  return page ? { title: `${page.title} · Docs`, description: page.summary } : {};
}

export default function Page({ params }: { params: { slug: string[] } }) {
  const slug = params.slug.join("/");
  if (slug === "guides/read" || slug === "guides/write" || slug === "contracts/balance-module") redirect("/docs");
  const page = docPage(slug);
  if (!page) notFound();
  return <DocsPage page={page} />;
}
