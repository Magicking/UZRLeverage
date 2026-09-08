"use client";

import { useState, useEffect } from "react";
import {
  useAccount,
  useWriteContract,
  useWaitForTransactionReceipt,
  useReadContract,
} from "wagmi";
import { useQueryClient } from "@tanstack/react-query";
import { formatUnits, maxUint256, parseUnits } from "viem";
import { UZRLeverageABI, ERC20ABI, CONTRACT_ADDRESSES } from "@/lib/contracts";

interface UnleverageFlashControlProps {
  contractAddress: `0x${string}` | undefined;
}

type ExitRoute = "pool" | "floor" | "par";

export function UnleverageFlashControl({ contractAddress }: UnleverageFlashControlProps) {
  const { address } = useAccount();
  const [route, setRoute] = useState<ExitRoute>("pool");
  const [fullClose, setFullClose] = useState(true);
  const [repayAssets, setRepayAssets] = useState<string>("");
  const [rtAmount, setRtAmount] = useState<string>("");
  const [minUsd0Out, setMinUsd0Out] = useState<string>("0");
  const queryClient = useQueryClient();

  const { data: rtBalance } = useReadContract({
    address: CONTRACT_ADDRESSES.RTUSD0,
    abi: ERC20ABI,
    functionName: "balanceOf",
    args: address ? [address] : undefined,
    query: { enabled: !!address && route === "par", refetchInterval: 5000 },
  });

  const { data: rtAllowance, refetch: refetchAllowance } = useReadContract({
    address: CONTRACT_ADDRESSES.RTUSD0,
    abi: ERC20ABI,
    functionName: "allowance",
    args: address && contractAddress ? [address, contractAddress] : undefined,
    query: { enabled: !!address && !!contractAddress && route === "par", refetchInterval: 5000 },
  });

  const { writeContract, data: hash, error, isPending } = useWriteContract();
  const {
    writeContract: writeApprove,
    data: approveHash,
    error: approveError,
    isPending: isApprovePending,
  } = useWriteContract();

  const { isLoading: isConfirming, isSuccess: isConfirmed } = useWaitForTransactionReceipt({
    hash,
  });
  const { isLoading: isApproveConfirming, isSuccess: isApproveConfirmed } =
    useWaitForTransactionReceipt({ hash: approveHash });

  useEffect(() => {
    if (isConfirmed) {
      queryClient.invalidateQueries();
    }
  }, [isConfirmed, queryClient]);

  useEffect(() => {
    if (isApproveConfirmed) {
      refetchAllowance();
    }
  }, [isApproveConfirmed, refetchAllowance]);

  const rtAmountWei = rtAmount ? parseUnits(rtAmount, 18) : 0n;
  const needsRtApproval =
    route === "par" && rtAmountWei > 0n && (rtAllowance ?? 0n) < rtAmountWei;

  const handleApproveRt = () => {
    if (!contractAddress || !address) return;
    writeApprove({
      address: CONTRACT_ADDRESSES.RTUSD0,
      abi: ERC20ABI,
      functionName: "approve",
      args: [contractAddress, maxUint256],
      account: address,
    });
  };

  const handleUnleverageFlash = () => {
    if (!contractAddress || !address) return;

    const repay = fullClose ? maxUint256 : parseUnits(repayAssets || "0", 18);
    if (!fullClose && repay <= 0n) return;

    const rt = route === "par" ? rtAmountWei : 0n;
    const useFloorExit = route === "floor";
    const minOut = minUsd0Out ? parseUnits(minUsd0Out, 18) : 0n;

    writeContract({
      address: contractAddress,
      abi: UZRLeverageABI,
      functionName: "unleverageFlash",
      args: [repay, rt, useFloorExit, minOut],
      account: address,
    });
  };

  const canSubmit =
    !!contractAddress &&
    !!address &&
    (fullClose || parseFloat(repayAssets || "0") > 0) &&
    (route !== "par" || (rtAmountWei > 0n && !needsRtApproval));

  return (
    <div className="bg-background-card border border-secondary/30 rounded-xl p-6 shadow-glow-yellow">
      <div className="flex items-center gap-2 mb-4">
        <h2 className="text-2xl font-bold text-secondary glow-text-secondary">
          Unleverage (Flash)
        </h2>
        <span className="text-xs font-semibold px-2 py-0.5 rounded-full border text-primary border-primary/50 bg-primary/10">
          New
        </span>
      </div>
      <p className="text-gray-400 mb-6 text-sm">
        Unwinds fully or partially in a single flashloaned transaction. Pick an exit route: sell
        collateral on the pool, exit at the Usd0PP floor price, or reconstruct at par with
        rt-USD0.
      </p>

      <div className="space-y-4">
        <div>
          <label className="block text-secondary font-semibold mb-2">Exit Route</label>
          <div className="grid grid-cols-3 gap-2">
            {(["pool", "floor", "par"] as ExitRoute[]).map((r) => (
              <button
                key={r}
                type="button"
                onClick={() => setRoute(r)}
                className={`px-3 py-2 rounded-lg text-sm font-semibold border transition-all ${
                  route === r
                    ? "bg-secondary text-black border-secondary"
                    : "bg-background border-secondary/50 text-secondary hover:border-secondary"
                }`}
              >
                {r === "pool" ? "Pool" : r === "floor" ? "Floor" : "Par (rt-USD0)"}
              </button>
            ))}
          </div>
        </div>

        <div>
          <label className="flex items-center gap-2 text-secondary font-semibold mb-2">
            <input
              type="checkbox"
              checked={fullClose}
              onChange={(e) => setFullClose(e.target.checked)}
              className="accent-secondary"
            />
            Full close (repay entire debt)
          </label>
          {!fullClose && (
            <input
              type="number"
              value={repayAssets}
              onChange={(e) => setRepayAssets(e.target.value)}
              min="0"
              step="0.0001"
              className="w-full px-4 py-2 bg-background border border-secondary/50 rounded-lg text-white focus:outline-none focus:border-secondary focus:shadow-glow-yellow"
              placeholder="USD0 debt to repay"
            />
          )}
        </div>

        {route === "par" && (
          <div>
            <label className="block text-secondary font-semibold mb-2">
              rt-USD0 to Redeem
              {rtBalance !== undefined && (
                <span className="text-gray-400 font-normal text-xs ml-2" suppressHydrationWarning>
                  (balance: {formatUnits(rtBalance, 18)})
                </span>
              )}
            </label>
            <input
              type="number"
              value={rtAmount}
              onChange={(e) => setRtAmount(e.target.value)}
              min="0"
              step="0.0001"
              className="w-full px-4 py-2 bg-background border border-secondary/50 rounded-lg text-white focus:outline-none focus:border-secondary focus:shadow-glow-yellow"
              placeholder="rt-USD0 amount (up to your collateral)"
            />
            {needsRtApproval && (
              <button
                onClick={handleApproveRt}
                disabled={isApprovePending || isApproveConfirming}
                className="mt-2 w-full px-4 py-2 bg-secondary/20 hover:bg-secondary/30 border border-secondary/50 rounded-lg text-secondary text-sm font-semibold transition-all disabled:opacity-50"
              >
                {isApprovePending || isApproveConfirming
                  ? "Approving..."
                  : "Approve rt-USD0"}
              </button>
            )}
          </div>
        )}

        <div>
          <label className="block text-secondary font-semibold mb-2">
            Min USD0 Out <span className="text-gray-400 font-normal text-xs">(slippage floor, optional)</span>
          </label>
          <input
            type="number"
            value={minUsd0Out}
            onChange={(e) => setMinUsd0Out(e.target.value)}
            min="0"
            step="0.0001"
            className="w-full px-4 py-2 bg-background border border-secondary/50 rounded-lg text-white focus:outline-none focus:border-secondary focus:shadow-glow-yellow"
            placeholder="0"
          />
        </div>

        <button
          onClick={handleUnleverageFlash}
          disabled={!canSubmit || isPending || isConfirming}
          className="w-full px-6 py-3 bg-secondary hover:bg-secondary-dark text-black font-bold rounded-lg transition-all duration-200 shadow-glow-yellow hover:shadow-glow-orange disabled:opacity-50 disabled:cursor-not-allowed disabled:hover:bg-secondary"
        >
          {isPending || isConfirming
            ? "Processing..."
            : isConfirmed
            ? "Success!"
            : "Unleverage (Flash)"}
        </button>
      </div>

      {(error || approveError) && (
        <div className="mt-4 p-4 bg-red-900/20 border border-red-500/50 rounded-lg">
          <p className="text-red-400 text-sm">
            Error: {(error || approveError)?.message || "Transaction failed"}
          </p>
        </div>
      )}

      {hash && (
        <div className="mt-4 p-4 bg-background hover border border-secondary/30 rounded-lg">
          <p className="text-secondary text-sm font-mono break-all">Tx Hash: {hash}</p>
        </div>
      )}
    </div>
  );
}
