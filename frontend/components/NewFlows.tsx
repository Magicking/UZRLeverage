const FLOWS = [
  {
    name: "leverageFlashMint",
    tag: "New",
    tagColor: "text-primary border-primary/50 bg-primary/10",
    description:
      "Builds the leveraged position in a single transaction using the lending market's free flashloan and Usd0PP.mint (1 USD0 -> 1 bUSD0 + 1 rt-USD0 at par). Mints at par instead of buying bUSD0 on the pool, and leaves the user holding rt-USD0 that unleverageFlash can later redeem at par via reconstruct.",
  },
  {
    name: "unleverageFlash",
    tag: "New",
    tagColor: "text-primary border-primary/50 bg-primary/10",
    description:
      "Unwinds the position (fully or partially) in a single transaction via flashloan, with a choice of exit route: par reconstruct (redeem rt-USD0 1:1, no pool fee or slippage), sell collateral on the pool at market, or exit at the Usd0PP floor price. Par exit consistently recovers the most equity; floor exit is the worst of the three.",
  },
  {
    name: "unleveragePosition",
    tag: "Legacy",
    tagColor: "text-gray-400 border-gray-500/50 bg-gray-500/10",
    description:
      "Pre-flashloan iterative unwind, kept as a comparison baseline against unleverageFlash: repays debt, withdraws collateral, and sells it on the pool one loop per transaction. No par/reconstruct or floor-price option, and stalls short of a full close on some positions.",
  },
];

export function NewFlows() {
  return (
    <div className="bg-background-card border border-secondary/30 rounded-xl p-6 shadow-glow-yellow mb-8">
      <h2 className="text-2xl font-bold text-secondary mb-2 glow-text-secondary">
        Contract Flows
      </h2>
      <p className="text-gray-400 mb-6 text-sm">
        Exit-route flows available on the current UZRLeverage contract.
      </p>
      <div className="space-y-4">
        {FLOWS.map((flow) => (
          <div
            key={flow.name}
            className="border border-primary/20 rounded-lg p-4 bg-background/50"
          >
            <div className="flex items-center gap-3 mb-2">
              <code className="text-primary font-mono font-bold">{flow.name}</code>
              <span
                className={`text-xs font-semibold px-2 py-0.5 rounded-full border ${flow.tagColor}`}
              >
                {flow.tag}
              </span>
            </div>
            <p className="text-gray-400 text-sm leading-relaxed">{flow.description}</p>
          </div>
        ))}
      </div>
    </div>
  );
}
