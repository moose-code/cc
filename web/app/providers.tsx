"use client";

import { RainbowKitProvider, darkTheme, lightTheme } from "@rainbow-me/rainbowkit";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { WagmiProvider } from "wagmi";
import { useEffect, useState } from "react";
import { wagmiConfig } from "@/lib/wagmi";
import { IndexerSync } from "@/components/IndexerSync";
import "@rainbow-me/rainbowkit/styles.css";

// Resolves the app theme: data-theme when set, else prefers-color-scheme.
function useResolvedDark() {
  const [dark, setDark] = useState(false);
  useEffect(() => {
    const root = document.documentElement;
    const mq = window.matchMedia("(prefers-color-scheme: dark)");
    const read = () => {
      const t = root.dataset.theme;
      setDark(t ? t === "dark" : mq.matches);
    };
    read();
    mq.addEventListener("change", read);
    const obs = new MutationObserver(read);
    obs.observe(root, { attributes: true, attributeFilter: ["data-theme"] });
    return () => {
      mq.removeEventListener("change", read);
      obs.disconnect();
    };
  }, []);
  return dark;
}

export function Providers({ children }: { children: React.ReactNode }) {
  const [queryClient] = useState(() => new QueryClient());
  const dark = useResolvedDark();
  // accent colours are CSS variables, so they follow the app tokens
  const opts = {
    accentColor: "var(--ink)",
    accentColorForeground: "var(--on-ink)",
    borderRadius: "none" as const,
    fontStack: "system" as const,
  };
  return (
    <WagmiProvider config={wagmiConfig}>
      <QueryClientProvider client={queryClient}>
        <RainbowKitProvider
          theme={dark ? darkTheme(opts) : lightTheme(opts)}
        >
          <IndexerSync />
          {children}
        </RainbowKitProvider>
      </QueryClientProvider>
    </WagmiProvider>
  );
}
