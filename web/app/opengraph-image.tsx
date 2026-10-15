import { ogContentType, ogImage, ogSize } from "@/lib/og";

export const alt = "credits engine";
export const size = ogSize;
export const contentType = ogContentType;

export default function Image() {
  return ogImage({ title: "Credit Cycle" });
}
