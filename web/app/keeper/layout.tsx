import type { Metadata } from "next";

export const metadata: Metadata = {
  title: "keeper",
  description: "engine pots, fee booking and buyback, with the next buyback timing.",
  openGraph: { title: "keeper", description: "engine pots, fee booking and buyback, with the next buyback timing." },
};

export default function Layout({ children }: { children: React.ReactNode }) {
  return children;
}
