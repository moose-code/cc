import { ogContentType, ogImage, ogSize } from "@/lib/og";

export const alt = "listings · credits engine";
export const size = ogSize;
export const contentType = ogContentType;

export default function Image() {
  return ogImage({ title: "listings", line: "Credits listed on CreditStrategy and OpenSea, by price over the engine bid." });
}
