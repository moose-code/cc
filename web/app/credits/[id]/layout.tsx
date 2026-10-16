import type { Metadata } from "next";
import { getToken, tokenDescription } from "@/lib/meta";

export async function generateMetadata({ params }: { params: { id: string } }): Promise<Metadata> {
  const id = Number(params.id);
  if (!Number.isInteger(id) || id < 0) return {};
  const t = await getToken("credit", id, false);
  const description = tokenDescription(t) || "a Credit of the Credit Cycle.";
  const title = `credit #${id}`;
  return { title, description, openGraph: { title, description }, twitter: { card: "summary_large_image", title, description } };
}

export default function Layout({ children }: { children: React.ReactNode }) {
  return children;
}
