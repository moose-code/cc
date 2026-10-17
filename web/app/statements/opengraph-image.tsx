import { ogContentType, ogImage, ogSize } from "@/lib/og";

export const alt = "statements · credits engine";
export const size = ogSize;
export const contentType = ogContentType;

export default function Image() {
  return ogImage();
}
