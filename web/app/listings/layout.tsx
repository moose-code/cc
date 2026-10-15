import type { Metadata } from "next";

export const metadata: Metadata = {
  title: "listings",
  description: "Credits listed on CreditStrategy and OpenSea, by price over the engine bid.",
  openGraph: { title: "listings", description: "Credits listed on CreditStrategy and OpenSea, by price over the engine bid." },
};

export default function Layout({ children }: { children: React.ReactNode }) {
  return children;
}
