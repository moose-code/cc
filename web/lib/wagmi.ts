import { connectorsForWallets, getDefaultConfig, type Wallet } from "@rainbow-me/rainbowkit";
import { createConfig, createConnector, http } from "wagmi";
import { mock } from "wagmi/connectors";
import { chain, isLocal, localAccount, rpcUrl, wcProjectId } from "./config";

// Local: the wagmi mock connector acting as localAccount, as the only wallet.
// No WalletConnect connector is created, so the page makes no WalletConnect
// requests.
const localWallet = (): Wallet => ({
  id: "local-account",
  name: "local account",
  iconUrl:
    "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 8 8'%3E%3Crect width='8' height='8' fill='%23000'/%3E%3C/svg%3E",
  iconBackground: "#000000",
  installed: true,
  createConnector: (details) =>
    createConnector((config) => ({
      ...mock({ accounts: [localAccount] })(config),
      ...details,
      // the mock connector forgets its session on reload; stay connected
      // until the user disconnects (wagmi clears recentConnectorId then)
      isAuthorized: async () => (await config.storage?.getItem("recentConnectorId")) === details.rkDetails.id,
    })),
});

export const wagmiConfig = isLocal
  ? createConfig({
      chains: [chain],
      transports: { 1: http(rpcUrl), 31337: http(rpcUrl) },
      connectors: connectorsForWallets(
        [{ groupName: "local", wallets: [localWallet] }],
        { appName: "credits engine", projectId: wcProjectId }
      ),
      ssr: true,
    })
  : getDefaultConfig({
      appName: "credits engine",
      projectId: wcProjectId,
      chains: [chain],
      transports: { [chain.id]: http(rpcUrl) },
      ssr: true,
    });
