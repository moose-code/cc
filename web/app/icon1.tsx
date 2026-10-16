import { ImageResponse } from "next/og";
import { logoUri } from "@/lib/og";

// PNG fallback of icon.svg for agents that ignore SVG icons.
export const size = { width: 32, height: 32 };
export const contentType = "image/png";

export default function Icon() {
  // eslint-disable-next-line @next/next/no-img-element
  return new ImageResponse(<img src={logoUri} width={32} height={32} alt="" />, size);
}
