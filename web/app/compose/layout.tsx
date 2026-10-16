import type { Metadata } from "next";

export const metadata: Metadata = {
  title: "composing next statement",
  description: "the credits queued to become the next statement.",
  openGraph: { title: "composing next statement", description: "the credits queued to become the next statement." },
};

export default function Layout({ children }: { children: React.ReactNode }) {
  return children;
}
