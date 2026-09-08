"use client";

import { useEffect, useState } from "react";
import { getStoredRpcUrl, setStoredRpcUrl } from "@/lib/rpc";

export function RpcSettings() {
  const [mounted, setMounted] = useState(false);
  const [url, setUrl] = useState("");
  const [saved, setSaved] = useState(false);

  useEffect(() => {
    setMounted(true);
    setUrl(getStoredRpcUrl() ?? "");
  }, []);

  if (!mounted) return null;

  const handleSave = () => {
    setStoredRpcUrl(url.trim());
    setSaved(true);
    // The wagmi transport is built once at module load, so a new fallback
    // RPC URL only takes effect after a reload.
    window.location.reload();
  };

  return (
    <div className="bg-background-card border border-primary/30 rounded-xl p-6">
      <h2 className="text-2xl font-bold text-primary mb-2 glow-text">RPC Endpoint</h2>
      <p className="text-gray-400 mb-4 text-sm">
        RPC calls are routed through your connected wallet&apos;s own provider whenever
        one is connected. This URL is only used as the fallback &mdash; before a wallet
        is connected, or if the wallet&apos;s provider fails. Leave blank to use the
        default public RPC.
      </p>
      <div className="flex gap-3">
        <input
          type="text"
          value={url}
          onChange={(e) => {
            setUrl(e.target.value);
            setSaved(false);
          }}
          placeholder="https://your-rpc-endpoint.example"
          className="flex-1 px-4 py-2 bg-background border border-primary/50 rounded-lg text-white font-mono text-sm focus:outline-none focus:border-primary focus:shadow-glow-orange"
        />
        <button
          onClick={handleSave}
          className="px-6 py-2 bg-primary hover:bg-primary-dark text-black font-bold rounded-lg transition-all duration-200 shadow-glow-orange hover:shadow-glow-yellow whitespace-nowrap"
        >
          Save & Reload
        </button>
      </div>
      {saved && <p className="text-primary text-xs mt-2">Saved.</p>}
    </div>
  );
}
