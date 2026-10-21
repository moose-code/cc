import type { Metadata } from "next";
import { notFound } from "next/navigation";
import { exchangeEnabled } from "@/lib/exchange-access";

export const metadata: Metadata = {
  title: "exchange",
  description: "Select Credits and exchange them for BALANCE at the engine's live bid, with a protected minimum payout.",
  robots: { index: false, follow: false },
};

export default function ExchangeLayout({ children }: { children: React.ReactNode }) {
  if (!exchangeEnabled(process.env.NODE_ENV, process.env.EXCHANGE_ENABLED)) notFound();
  return children;
}
