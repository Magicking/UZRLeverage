"use client";

import { useState, useEffect } from "react";
import { useAccount, useDisconnect, useConnect } from "wagmi";

// Wallets that announce via EIP-6963 (Brave, MetaMask, Rabby, etc. when more
// than one extension is installed) show up as their own named connector
// instead of claiming window.ethereum, so wagmi's `connectors` list already
// has a distinct entry per detected wallet when it's available.
const WALLET_OPTIONS = [
  { key: "brave", label: "Brave Wallet", icon: "🦁", match: (n: string) => n.includes("brave") },
  { key: "metamask", label: "MetaMask", icon: "🦊", match: (n: string) => n.includes("metamask") },
] as const;

export function WalletConnect() {
  const [mounted, setMounted] = useState(false);
  const { address, isConnected } = useAccount();
  const { disconnect } = useDisconnect();
  const { connect, connectors, error } = useConnect();

  const findWalletConnector = (match: (name: string) => boolean) =>
    connectors.find((c) => match(c.name.toLowerCase()));

  // Fallback for any other EIP-6963-announced wallet (Rabby, etc.) not
  // covered by the dedicated cards. Deliberately excludes the generic static
  // "injected" connector (id === "injected"): on a single-Brave-or-MetaMask
  // browser it resolves to the exact same provider as the matching card
  // above, so surfacing it here would just offer a confusing duplicate.
  const pickOtherConnector = () =>
    connectors.find(
      (c) => c.id !== "injected" && !WALLET_OPTIONS.some((w) => w.match(c.name.toLowerCase()))
    );

  // Prevent hydration mismatch by only rendering after mount
  useEffect(() => {
    setMounted(true);
  }, []);

  // Render consistent structure during SSR
  if (!mounted) {
    return (
      <div className="flex items-center gap-4">
        <button
          disabled
          className="px-6 py-2 bg-primary/50 text-black/50 font-bold rounded-lg cursor-not-allowed"
        >
          Connect Wallet
        </button>
      </div>
    );
  }

  if (isConnected) {
    return (
      <div className="flex items-center gap-4">
        <div className="px-4 py-2 bg-background-card border border-primary/50 rounded-lg">
          <span className="text-primary font-mono text-sm" suppressHydrationWarning>
            {address ? `${address.slice(0, 6)}...${address.slice(-4)}` : ""}
          </span>
        </div>
        <button
          onClick={() => disconnect()}
          className="px-6 py-2 bg-primary hover:bg-primary-dark text-black font-bold rounded-lg transition-all duration-200 shadow-glow-orange hover:shadow-glow-yellow"
        >
          Disconnect
        </button>
      </div>
    );
  }

  const otherConnector = pickOtherConnector();

  return (
    <div className="flex flex-col items-end gap-2">
      <div className="flex items-center gap-3">
        {WALLET_OPTIONS.map((wallet) => {
          const connector = findWalletConnector(wallet.match);
          const detected = !!connector;
          return (
            <button
              key={wallet.key}
              onClick={() => connector && connect({ connector })}
              disabled={!detected}
              title={detected ? `Connect with ${wallet.label}` : `${wallet.label} not detected`}
              className={`flex flex-col items-center gap-1 px-4 py-2 rounded-lg border transition-all duration-200 ${
                detected
                  ? "bg-background-card border-primary/50 hover:border-primary hover:shadow-glow-orange cursor-pointer"
                  : "bg-background-card/50 border-primary/10 opacity-40 cursor-not-allowed"
              }`}
            >
              <span className="text-2xl leading-none">{wallet.icon}</span>
              <span className="text-xs font-semibold text-white whitespace-nowrap">
                {wallet.label}
              </span>
              <span className={`text-[10px] ${detected ? "text-primary" : "text-gray-500"}`}>
                {detected ? "Detected" : "Not detected"}
              </span>
            </button>
          );
        })}
      </div>
      {otherConnector && (
        <button
          onClick={() => connect({ connector: otherConnector })}
          className="text-gray-400 hover:text-primary text-xs underline"
        >
          Connect with another wallet ({otherConnector.name})
        </button>
      )}
      {connectors.length === 0 && (
        <p className="text-red-400 text-xs">No wallet extension detected.</p>
      )}
      {error && <p className="text-red-400 text-xs max-w-xs text-right">{error.message}</p>}
    </div>
  );
}