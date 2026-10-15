import { ImageResponse } from "next/og";
import { logoUri } from "@/lib/og";

export const size = { width: 180, height: 180 };
export const contentType = "image/png";

export default function AppleIcon() {
  return new ImageResponse(
    (
      <div style={{ width: "100%", height: "100%", display: "flex", alignItems: "center", justifyContent: "center", background: "#f6f5f0" }}>
        {/* eslint-disable-next-line @next/next/no-img-element */}
        <img src={logoUri} width={108} height={108} alt="" />
      </div>
    ),
    size,
  );
}
