import { getDefaultConfig } from "@rainbow-me/rainbowkit";
import { http } from "wagmi";
import { mainnet } from "wagmi/chains";
import { rpcUrl, wcProjectId } from "./config";

export const wagmiConfig = getDefaultConfig({
  appName: "credits engine",
  projectId: wcProjectId,
  chains: [mainnet],
  transports: { [mainnet.id]: http(rpcUrl) },
  ssr: true,
});
