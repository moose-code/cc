import type { Metadata } from "next";
import { siteName } from "@/lib/site";

export const metadata: Metadata = {
  title: { default: "statements", template: `%s · ${siteName}` },
  description: "statements composed from 80 Credits, with format, rating and sale state.",
  openGraph: { title: "statements", description: "statements composed from 80 Credits, with format, rating and sale state." },
};

export default function Layout({ children }: { children: React.ReactNode }) {
  return children;
}
