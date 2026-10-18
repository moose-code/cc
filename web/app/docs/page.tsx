import type { Metadata } from "next";
import { DocsPage } from "@/components/DocsPage";
import { docPages } from "@/lib/docs-content";

export const metadata: Metadata = { title: "Documentation", description: "Contracts, guides, and onchain integration reference for the CC engine." };

export default function Page() {
  return <DocsPage page={docPages[0]} />;
}
