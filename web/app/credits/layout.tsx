import type { Metadata } from "next";

export const metadata: Metadata = {
  title: { default: "credits", template: "%s · credits engine" },
  description: "every Credit the engine holds, with rating, plates and cost.",
  openGraph: { title: "credits", description: "every Credit the engine holds, with rating, plates and cost." },
};

export default function Layout({ children }: { children: React.ReactNode }) {
  return children;
}
