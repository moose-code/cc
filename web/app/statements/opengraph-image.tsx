import { ogContentType, ogImage, ogSize } from "@/lib/og";
import { siteName } from "@/lib/site";

export const alt = `statements · ${siteName}`;
export const size = ogSize;
export const contentType = ogContentType;

export default function Image() {
  return ogImage();
}
