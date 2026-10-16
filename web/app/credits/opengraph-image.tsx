import { ogContentType, ogImage, ogSize } from "@/lib/og";
import { getCounts } from "@/lib/meta";

export const alt = "credits · credits engine";
export const size = ogSize;
export const contentType = ogContentType;

export default async function Image() {
  const c = await getCounts();
  return ogImage({ title: "credits", line: "every Credit the engine holds, with rating, plates and cost.", stat: c ? `${c.held.toLocaleString("en-US")} held` : undefined });
}
