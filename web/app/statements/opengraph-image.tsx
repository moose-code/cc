import { ogContentType, ogImage, ogSize } from "@/lib/og";
import { getCounts } from "@/lib/meta";

export const alt = "statements · credits engine";
export const size = ogSize;
export const contentType = ogContentType;

export default async function Image() {
  const c = await getCounts();
  return ogImage({ title: "statements", line: "statements composed from 80 Credits, with format, rating and sale state.", stat: c ? `${c.statements.toLocaleString("en-US")} composed` : undefined });
}
