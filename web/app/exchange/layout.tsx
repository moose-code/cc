import type { Metadata } from "next";

export const metadata: Metadata = {
  title: "exchange",
  description: "Select Credits and exchange them for BALANCE at the engine's live bid, with a protected minimum payout.",
};

export default function ExchangeLayout({ children }: { children: React.ReactNode }) {
  return children;
}
