import { getDefaultConfig } from "@rainbow-me/rainbowkit";
import { createConfig, createConnector, http } from "wagmi";
import { mock } from "wagmi/connectors";
import { chain, isLocal, localAccounts, rpcUrl, wcProjectId } from "./config";

// Local: one mock connector per record account, so the header switches accounts
// by connecting another connector. No WalletConnect connector exists, so the
// page makes no WalletConnect requests.
const localConnectors = localAccounts.map((a) =>
  createConnector((config) => ({
    ...mock({ accounts: [a.address] })(config),
    id: `local-${a.name}`,
    name: a.name,
  }))
);

export const wagmiConfig = isLocal
  ? createConfig({
      chains: [chain],
      transports: { 1: http(rpcUrl), 31337: http(rpcUrl) },
      connectors: localConnectors,
      ssr: true,
    })
  : getDefaultConfig({
      appName: "credits engine",
      projectId: wcProjectId,
      chains: [chain],
      transports: { [chain.id]: http(rpcUrl) },
      ssr: true,
    });
