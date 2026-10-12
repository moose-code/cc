import type { Metadata } from "next";
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

export default function RootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <html lang="en">
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
