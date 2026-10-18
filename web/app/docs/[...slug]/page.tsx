import type { Metadata } from "next";
import { notFound } from "next/navigation";
import { DocsPage } from "@/components/DocsPage";
import { docPage, docPages } from "@/lib/docs-content";

export function generateStaticParams() {
  return docPages.filter((page) => page.slug).map((page) => ({ slug: page.slug.split("/") }));
}

export function generateMetadata({ params }: { params: { slug: string[] } }): Metadata {
  const page = docPage(params.slug.join("/"));
  return page ? { title: `${page.title} · Docs`, description: page.summary } : {};
}

export default function Page({ params }: { params: { slug: string[] } }) {
  const page = docPage(params.slug.join("/"));
  if (!page) notFound();
  return <DocsPage page={page} />;
}
