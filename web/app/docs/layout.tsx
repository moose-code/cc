import type { ReactNode } from "react";
import { DocsNav } from "@/components/DocsNav";
import "./docs.css";

export default function DocsLayout({ children }: { children: ReactNode }) {
  return <div className="docs-shell"><DocsNav /><main className="docs-main">{children}</main></div>;
}
