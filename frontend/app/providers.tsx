"use client";

import { WagmiProvider, createConfig, fallback, http, unstable_connector } from "wagmi";
import { mainnet } from "wagmi/chains";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { injected } from "wagmi/connectors";
import { getStoredRpcUrl } from "@/lib/rpc";

// Prefer routing RPC calls through the connected wallet's own provider
// (unstable_connector) so reads use whatever endpoint the wallet itself is
// configured with. http(getStoredRpcUrl()) is only the fallback for when no
// wallet is connected yet, or the wallet's provider request fails; passing
// undefined there falls back further to wagmi/viem's built-in default RPC.
const config = createConfig({
  chains: [mainnet],
  connectors: [injected({ shimDisconnect: true })],
  transports: {
    [mainnet.id]: fallback([
      unstable_connector({ type: "injected" }),
      http(getStoredRpcUrl()),
    ]),
  },
});

const queryClient = new QueryClient();

export function Providers({ children }: { children: React.ReactNode }) {
  return (
    <WagmiProvider config={config}>
      <QueryClientProvider client={queryClient}>{children}</QueryClientProvider>
    </WagmiProvider>
  );
}