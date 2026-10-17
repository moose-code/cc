// Shared 1200x630 Open Graph renderer (next/og): the CC logo centered on paper. Colors are literal hex values; an
// image has no CSS variables.
import { ImageResponse } from "next/og";

export const ogSize = { width: 1200, height: 630 };
export const ogContentType = "image/png";

const PAPER = "#f6f5f0";

// The logo at rest (web/design/logo/README.md) as an SVG data URI; the squares multiply where they overlap. Used
// tight for the favicon and app icon.
const LOGO_SVG = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100"><g style="isolation:isolate"><rect x="6" y="6" width="58" height="58" fill="#00a3e0" style="mix-blend-mode:multiply"/><rect x="36" y="6" width="58" height="58" fill="#e5007e" style="mix-blend-mode:multiply"/><rect x="36" y="36" width="58" height="58" fill="#ffd400" style="mix-blend-mode:multiply"/></g></svg>`;
export const logoUri = `data:image/svg+xml;base64,${Buffer.from(LOGO_SVG).toString("base64")}`;

// The same logo with the credit-artwork margin: the 88-unit art fills the central 50%, 25% whitespace on each side.
const LOGO_OG_SVG = LOGO_SVG.replace('viewBox="0 0 100 100"', 'viewBox="-38 -38 176 176"');
const logoOgUri = `data:image/svg+xml;base64,${Buffer.from(LOGO_OG_SVG).toString("base64")}`;

/** The OG image: the logo centered on a paper card, with the credit-artwork margin. */
export function ogImage() {
  return new ImageResponse(
    (
      <div style={{ width: "100%", height: "100%", display: "flex", alignItems: "center", justifyContent: "center", background: PAPER }}>
        {/* eslint-disable-next-line @next/next/no-img-element */}
        <img src={logoOgUri} width={630} height={630} alt="" />
      </div>
    ),
    { ...ogSize },
  );
}
