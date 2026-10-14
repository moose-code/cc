import { connectorsForWallets, getDefaultConfig } from "@rainbow-me/rainbowkit";
import { createConfig, createConnector, http } from "wagmi";
import { injectedWallet } from "@rainbow-me/rainbowkit/wallets";
import { mock } from "wagmi/connectors";
import { chain, isLocal, localAccounts, rpcUrl, wcProjectId } from "./config";

const ICON =
  "data:image/svg+xml;utf8," +
  encodeURIComponent('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32"><rect width="32" height="32" fill="#111"/><path d="M8 20h16M8 12h16" stroke="#fff" stroke-width="3"/></svg>');

// wagmi's id of the connector used last, in the storage key wagmi writes.
const recentId = () => {
  try {
    return JSON.parse(localStorage.getItem("wagmi.recentConnectorId") ?? "null");
  } catch {
    return null;
  }
};

// Local: one wallet in RainbowKit's list per record account except `owner`, each a
// mock connector that anvil (--auto-impersonate) signs for. `owner` is the dev wallet
// address; the injected browser wallet (any EIP-6963 wallet) signs for it. The mock
// connector holds its connected state in memory, so the last used account starts connected and
// wagmi reconnects it on reload. No WalletConnect connector exists, so the page
// makes no WalletConnect requests.
const localWallets = localAccounts.filter((a) => a.name !== "owner").map((a) => () => ({
  id: `local-${a.name}`,
  name: a.name,
  iconUrl: ICON,
  iconBackground: "#111111",
  installed: true,
  createConnector: (details: { rkDetails: object }) =>
    createConnector((config) => ({ ...mock({ accounts: [a.address], features: { reconnect: true, defaultConnected: recentId() === `local-${a.name}` } })(config), ...details, id: `local-${a.name}`, name: a.name })),
}));

export const wagmiConfig = isLocal
  ? createConfig({
      chains: [chain],
      transports: { 1: http(rpcUrl), 31337: http(rpcUrl) },
      connectors: connectorsForWallets(
        [
          { groupName: "local accounts", wallets: localWallets as any },
          { groupName: "browser wallet", wallets: [injectedWallet] },
        ],
        {
          appName: "credits engine",
          projectId: wcProjectId,
        }
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
