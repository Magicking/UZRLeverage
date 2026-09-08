"use client";

import { useState, useEffect } from "react";
import { useAccount, useWriteContract, useWaitForTransactionReceipt } from "wagmi";
import { useQueryClient } from "@tanstack/react-query";
import { parseUnits } from "viem";
import { UZRLeverageABI } from "@/lib/contracts";

interface LeverageFlashMintControlProps {
  contractAddress: `0x${string}` | undefined;
}

export function LeverageFlashMintControl({ contractAddress }: LeverageFlashMintControlProps) {
  const { address } = useAccount();
  const [borrowAmount, setBorrowAmount] = useState<string>("");
  const queryClient = useQueryClient();

  const { writeContract, data: hash, error, isPending } = useWriteContract();

  const { isLoading: isConfirming, isSuccess: isConfirmed } =
    useWaitForTransactionReceipt({
      hash,
    });

  useEffect(() => {
    if (isConfirmed) {
      queryClient.invalidateQueries();
    }
  }, [isConfirmed, queryClient]);

  const handleLeverageFlashMint = () => {
    if (!contractAddress || !address || !borrowAmount) return;

    const amountNum = parseFloat(borrowAmount);
    if (isNaN(amountNum) || amountNum <= 0) return;

    writeContract({
      address: contractAddress,
      abi: UZRLeverageABI,
      functionName: "leverageFlashMint",
      args: [parseUnits(borrowAmount, 18)],
      account: address,
    });
  };

  const isValidAmount = parseFloat(borrowAmount || "0") > 0;

  return (
    <div className="bg-background-card border border-primary/30 rounded-xl p-6 shadow-glow-orange">
      <div className="flex items-center gap-2 mb-4">
        <h2 className="text-2xl font-bold text-primary glow-text">Leverage (Flash Mint)</h2>
        <span className="text-xs font-semibold px-2 py-0.5 rounded-full border text-primary border-primary/50 bg-primary/10">
          New
        </span>
      </div>
      <p className="text-gray-400 mb-6 text-sm">
        Build the position in a single transaction: flashloans USD0, mints bUSD0 + rt-USD0 at par
        via Usd0PP, supplies the bUSD0, and repays the flashloan by borrowing. rt-USD0 lands
        directly in your wallet &mdash; keep it to exit at par later with unleverageFlash.
      </p>

      <div className="space-y-4">
        <div>
          <label className="block text-secondary font-semibold mb-2">Borrow Amount (USD0)</label>
          <input
            type="number"
            value={borrowAmount}
            onChange={(e) => setBorrowAmount(e.target.value)}
            min="0"
            step="0.0001"
            className="w-full px-4 py-2 bg-background border border-primary/50 rounded-lg text-white focus:outline-none focus:border-primary focus:shadow-glow-orange"
            placeholder="USD0 to flashloan and leave borrowed"
          />
          <p className="text-gray-400 text-xs mt-1">
            Reverts if it violates the market LTV: borrowAmount &le; 0.87 &times; (equity + borrowAmount).
          </p>
        </div>

        <button
          onClick={handleLeverageFlashMint}
          disabled={!contractAddress || !address || !isValidAmount || isPending || isConfirming}
          className="w-full px-6 py-3 bg-primary hover:bg-primary-dark text-black font-bold rounded-lg transition-all duration-200 shadow-glow-orange hover:shadow-glow-yellow disabled:opacity-50 disabled:cursor-not-allowed disabled:hover:bg-primary"
        >
          {isPending || isConfirming
            ? "Processing..."
            : isConfirmed
            ? "Success!"
            : "Leverage (Flash Mint)"}
        </button>
      </div>

      {error && (
        <div className="mt-4 p-4 bg-red-900/20 border border-red-500/50 rounded-lg">
          <p className="text-red-400 text-sm">Error: {error.message || "Transaction failed"}</p>
        </div>
      )}

      {hash && (
        <div className="mt-4 p-4 bg-background hover border border-primary/30 rounded-lg">
          <p className="text-primary text-sm font-mono break-all">Tx Hash: {hash}</p>
        </div>
      )}
    </div>
  );
}
