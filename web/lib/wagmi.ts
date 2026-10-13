import { getDefaultConfig } from "@rainbow-me/rainbowkit";
import { http } from "wagmi";
import { chain, rpcUrl, wcProjectId } from "./config";

export const wagmiConfig = getDefaultConfig({
  appName: "credits engine",
  projectId: wcProjectId,
  chains: [chain],
  transports: { [chain.id]: http(rpcUrl) },
  ssr: true,
});
