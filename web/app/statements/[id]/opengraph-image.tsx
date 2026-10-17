import { ogContentType, ogImage, ogSize } from "@/lib/og";

export const alt = "statement";
export const size = ogSize;
export const contentType = ogContentType;

export default function Image() {
  return ogImage();
}
