import type { Metadata } from "next";

export const metadata: Metadata = {
  title: "balance",
  description: "trade $BALANCE, the token the engine bids with and statements redeem for.",
  openGraph: { title: "balance", description: "trade $BALANCE, the token the engine bids with and statements redeem for." },
};

export default function Layout({ children }: { children: React.ReactNode }) {
  return children;
}
