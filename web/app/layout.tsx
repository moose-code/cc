import type { Metadata } from "next";
import { IBM_Plex_Mono } from "next/font/google";
import { Providers } from "./providers";
import { Header } from "@/components/Header";
import { StatsBar } from "@/components/StatsBar";
import { Footer } from "@/components/Footer";
import "./globals.css";

export const metadata: Metadata = {
  title: "credits engine",
  description:
    "an erc20 whose swap fees buy credits, compose them into statements, and sell each at a falling price. independent dashboard.",
};

const plex = IBM_Plex_Mono({
  subsets: ["latin"],
  weight: ["400", "500", "600"],
  variable: "--font-plex",
  display: "swap",
});

// Applies the stored theme choice before first paint. "auto" leaves data-theme
// unset so the CSS follows prefers-color-scheme. Same key and JSON format as
// ThemeControl in Footer.tsx.
const THEME_SCRIPT = `try{var t=JSON.parse(localStorage.getItem("cc:theme"));if(t==="light"||t==="dark")document.documentElement.dataset.theme=t}catch(e){}`;

export default function RootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <html lang="en" className={plex.variable} suppressHydrationWarning>
      <head>
        <script dangerouslySetInnerHTML={{ __html: THEME_SCRIPT }} />
      </head>
      <body>
        <Providers>
          <div className="app">
            <Header />
            <StatsBar />
            {children}
            <Footer />
          </div>
        </Providers>
      </body>
    </html>
  );
}
