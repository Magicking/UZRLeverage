"use client";

import { useState, useEffect } from "react";
import { WalletConnect } from "@/components/WalletConnect";
import { DeployContract } from "@/components/DeployContract";
import { LeverageControl } from "@/components/LeverageControl";
import { UnleverageControl } from "@/components/UnleverageControl";
import { UserPosition } from "@/components/UserPosition";
import { AuthorizeContract } from "@/components/AuthorizeContract";
import { ContractBalances } from "@/components/ContractBalances";
import { TransferUSD0 } from "@/components/TransferUSD0";
import { NewFlows } from "@/components/NewFlows";
import { RpcSettings } from "@/components/RpcSettings";
import { LeverageFlashMintControl } from "@/components/LeverageFlashMintControl";
import { UnleverageFlashControl } from "@/components/UnleverageFlashControl";

export default function Home() {
  const [contractAddress, setContractAddress] = useState<
    `0x${string}` | undefined
  >(undefined);
  const [mounted, setMounted] = useState(false);

  // Load contract address from localStorage on mount
  useEffect(() => {
    setMounted(true);
    if (typeof window !== "undefined") {
      const stored = localStorage.getItem("uzrLeverageContract");
      if (stored && stored.startsWith("0x") && stored.length === 42) {
        setContractAddress(stored as `0x${string}`);
      }
    }
  }, []);

  const handleContractDeployed = (address: string) => {
    setContractAddress(address as `0x${string}`);
    if (typeof window !== "undefined") {
      localStorage.setItem("uzrLeverageContract", address);
    }
  };

  return (
    <main className="min-h-screen bg-background cyber-bg">
      {/* Header */}
      <header className="border-b border-primary/30 bg-background-card/50 backdrop-blur-sm sticky top-0 z-50">
        <div className="container mx-auto px-4 py-4 flex justify-between items-center">
          <h1 className="text-3xl font-bold glow-text text-primary">
            UZR Leverage
          </h1>
          <WalletConnect />
        </div>
      </header>

      {/* Main Content */}
      <div className="container mx-auto px-4 py-8 max-w-7xl">
        {/* Disclaimer Banner */}
        <div className="mb-8 p-6 bg-red-900/20 border-2 border-red-500/50 rounded-xl shadow-glow-orange">
          <h3 className="text-xl font-bold text-red-400 mb-3 flex items-center gap-2">
            ⚠️ EXPERIMENTAL SOFTWARE - USE AT YOUR OWN RISK
          </h3>
          <p className="text-red-300 text-sm leading-relaxed">
            This software is <strong>experimental</strong> and has <strong>not been audited</strong>.
            It is provided &quot;as is&quot; without warranty of any kind. Use of this software may result in
            <strong> financial loss</strong>. The authors and contributors are not responsible for any losses,
            damages, or liabilities that may arise from the use of this software.{" "}
            <strong className="text-red-200">You use this software at your own risk.</strong>
          </p>
        </div>

        <div className="mb-8 text-center">
          <h2 className="text-4xl font-bold mb-4 glow-text text-primary">
            Recursive Leverage Platform
          </h2>
          <p className="text-gray-400 text-lg">
            Leverage and deleverage positions on UZR Lending Market
          </p>
        </div>

        {/* Contract Flows */}
        <NewFlows />

        {/* RPC Settings */}
        <div className="mb-8">
          <RpcSettings />
        </div>

        {/* Contract Address Input */}
        {mounted && !contractAddress && (
          <div className="mb-8 bg-background-card border border-primary/30 rounded-xl p-6">
            <h3 className="text-xl font-bold text-primary mb-4">
              Contract Address
            </h3>
            <p className="text-gray-400 mb-4 text-sm">
              Deploy a new contract below or enter an existing contract address:
            </p>
            <input
              type="text"
              placeholder="0x..."
              className="w-full px-4 py-2 bg-background border border-primary/50 rounded-lg text-white font-mono focus:outline-none focus:border-primary focus:shadow-glow-orange"
              onChange={(e) => {
                const value = e.target.value.trim();
                if (value.startsWith("0x") && value.length === 42) {
                  setContractAddress(value as `0x${string}`);
                  localStorage.setItem("uzrLeverageContract", value);
                }
              }}
            />
          </div>
        )}

        {/* Contract Address Display */}
        {mounted && contractAddress && (
          <div className="mb-8 bg-background-card border border-primary/30 rounded-xl p-4">
            <div className="flex items-center justify-between">
              <div>
                <p className="text-gray-400 text-sm mb-1">Active Contract</p>
                <p className="text-primary font-mono text-sm break-all" suppressHydrationWarning>
                  {contractAddress}
                </p>
              </div>
              <button
                onClick={() => {
                  setContractAddress(undefined);
                  localStorage.removeItem("uzrLeverageContract");
                }}
                className="px-4 py-2 bg-red-900/20 hover:bg-red-900/30 border border-red-500/50 rounded-lg text-red-400 text-sm transition-all"
              >
                Clear
              </button>
            </div>
          </div>
        )}

        {/* Contract Balances */}
        {mounted && contractAddress && (
          <ContractBalances contractAddress={contractAddress} />
        )}

        {/* Transfer USD0 Button */}
        {mounted && contractAddress && (
          <TransferUSD0 contractAddress={contractAddress} />
        )}

        {/* Authorization Button */}
        {mounted && contractAddress && (
          <AuthorizeContract contractAddress={contractAddress} />
        )}

        {/* Grid Layout */}
        <div className="grid grid-cols-1 lg:grid-cols-2 gap-8 mb-8">
          {/* Deploy Contract */}
          <DeployContract onDeployed={handleContractDeployed} />

          {/* User Position */}
          <UserPosition contractAddress={contractAddress} />
        </div>

        {/* Flash Controls (new flows) */}
        <div className="grid grid-cols-1 lg:grid-cols-2 gap-8 mb-8">
          <LeverageFlashMintControl contractAddress={contractAddress} />
          <UnleverageFlashControl contractAddress={contractAddress} />
        </div>

        {/* Legacy Iterative Controls */}
        <div className="mb-4 text-center">
          <p className="text-gray-500 text-sm uppercase tracking-wide">Legacy Iterative Flows</p>
        </div>
        <div className="grid grid-cols-1 lg:grid-cols-2 gap-8">
          <LeverageControl contractAddress={contractAddress} />
          <UnleverageControl contractAddress={contractAddress} />
        </div>
      </div>

      {/* Footer */}
      <footer className="border-t border-primary/30 mt-16 py-8">
        <div className="container mx-auto px-4 text-center text-gray-400 text-sm">
          <p>UZR Leverage - Built for recursive leverage operations</p>
        </div>
      </footer>
    </main>
  );
}