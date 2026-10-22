import type { Metadata } from "next";

export const metadata: Metadata = {
  title: "credit / balance comparison",
  description: "Read-only comparison of Credit asks and BALANCE conversion value.",
  robots: { index: false, follow: false, noarchive: true, nosnippet: true },
};

export default function MarketCompareLayout({ children }: { children: React.ReactNode }) {
  return children;
}
