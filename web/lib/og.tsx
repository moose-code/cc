// Shared 1200x630 Open Graph renderer (next/og). Colors are literal hex values: an image has no CSS variables.
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { ImageResponse } from "next/og";
import { siteDescription } from "./site";

export const ogSize = { width: 1200, height: 630 };
export const ogContentType = "image/png";

const PAPER = "#f6f5f0";
const INK = "#1a1a1a";
const MUTED = "#6e6c64";

// Read from disk relative to the web/ root (the server runs with it as cwd).
const font = (f: string) => readFile(join(process.cwd(), "app", "fonts", f));

// The logo as an SVG data URI; the squares multiply where they overlap.
const LOGO_SVG = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32"><g style="isolation:isolate"><rect width="22" height="22" fill="#00a3e0" style="mix-blend-mode:multiply"/><rect x="5" y="5" width="22" height="22" fill="#e5007e" style="mix-blend-mode:multiply"/><rect x="10" y="10" width="22" height="22" fill="#ffd400" style="mix-blend-mode:multiply"/></g></svg>`;
export const logoUri = `data:image/svg+xml;base64,${Buffer.from(LOGO_SVG).toString("base64")}`;

interface OgProps {
  title: string; // large heading
  line?: string; // one-line description under the heading
  stat?: string; // headline number or state, bottom left
  art?: string; // token art as a data: URI, printed on white at the right
}

/** The OG image: paper background, logo and wordmark, heading, description, optional stat and token art. */
export async function ogImage({ title, line = siteDescription, stat, art }: OgProps) {
  const [regular, semi] = await Promise.all([font("IBMPlexMono-Regular.ttf"), font("IBMPlexMono-SemiBold.ttf")]);
  return new ImageResponse(
    (
      <div style={{ width: "100%", height: "100%", display: "flex", background: PAPER, color: INK, padding: 64, fontFamily: "Plex" }}>
        <div style={{ display: "flex", flexDirection: "column", justifyContent: "space-between", flex: 1 }}>
          <div style={{ display: "flex", alignItems: "center" }}>
            {/* eslint-disable-next-line @next/next/no-img-element */}
            <img src={logoUri} width={72} height={72} alt="" />
            <div style={{ display: "flex", marginLeft: 28, fontSize: 40, fontWeight: 600 }}>CC</div>
            <div style={{ display: "flex", marginLeft: 16, fontSize: 40, color: MUTED }}>engine</div>
          </div>
          <div style={{ display: "flex", flexDirection: "column" }}>
            <div style={{ display: "flex", fontSize: art ? 68 : 96, fontWeight: 600, lineHeight: 1.05 }}>{title}</div>
            <div style={{ display: "flex", marginTop: 28, fontSize: 30, lineHeight: 1.4, color: MUTED, maxWidth: art ? 560 : 960 }}>{line}</div>
          </div>
          <div style={{ display: "flex", fontSize: 44, fontWeight: 600, height: 56 }}>{stat ?? ""}</div>
        </div>
        {art && (
          <div style={{ display: "flex", width: 502, height: 502, alignSelf: "center", background: "#ffffff", border: `1px solid #d9d7cf`, marginLeft: 48 }}>
            {/* eslint-disable-next-line @next/next/no-img-element */}
            <img src={art} width={500} height={500} alt="" style={{ objectFit: "contain" }} />
          </div>
        )}
      </div>
    ),
    {
      ...ogSize,
      fonts: [
        { name: "Plex", data: regular, weight: 400, style: "normal" },
        { name: "Plex", data: semi, weight: 600, style: "normal" },
      ],
    },
  );
}
