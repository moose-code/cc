import type { Metadata } from "next";

export const metadata: Metadata = {
  title: "sell to the engine",
  description: "sell Credits to the engine at its standing bid, priced by rating.",
  openGraph: { title: "sell to the engine", description: "sell Credits to the engine at its standing bid, priced by rating." },
};

export default function Layout({ children }: { children: React.ReactNode }) {
  return children;
}
