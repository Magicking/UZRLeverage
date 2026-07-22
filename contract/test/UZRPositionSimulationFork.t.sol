// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.30;

import "forge-std/Test.sol";
import "forge-std/console.sol";

import {UZRLeverage} from "../src/UZRLeverage.sol";
import {ILendingMarket} from "../src/interfaces/ILendingMarket.sol";
import {Id, MarketParams} from "../src/interfaces/ILendingMarketBase.sol";
import {IUsd0PP} from "../src/interfaces/IUsd0PP.sol";
import {MarketParamsLib} from "../src/libraries/MarketParamsLib.sol";
import {UZRUnwindQuoter} from "../src/lens/UZRUnwindQuoter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title UZRPositionSimulationBase
/// @notice Simulates unwinding a real on-chain position through UZRLeverage, comparing the
///         three exit routes (pool sale, floor price, par reconstruct) and logging the gain.
///         Concrete suites at the bottom of this file pin one target address each.
abstract contract UZRPositionSimulationBase is Test {
    using MarketParamsLib for MarketParams;

    // Public gateway also used by the sibling usual-rt-arb repo's fork tests
    string constant RPC_URL = "https://mainnet.gateway.tenderly.co/49LPuZlg4TTIBIZohMSsqL";
    uint256 constant FORK_BLOCK = 25544764;

    address constant UZR_LENDING_MARKET = 0xa428723eE8ffD87088C36121d72100B43F11fb6A;
    address constant BUSD0 = 0x35D8949372D46B7a3D5A56006AE77B215fc69bC0;
    address constant USD0 = 0x73A15FeD60Bf67631dC6cd7Bc5B6e8da8190aCF5;
    address constant RTUSD0 = 0x82DCA22b48B14DE38ccf83B03330120c4b8acFe9;
    address constant ORACLE = 0x30Da78355FcEA04D1fa34AF3c318BE203C6F2145;
    address constant IRM = 0xdfCF197B0B65066183b04B88d50ACDC0C4b01385;
    address constant WHITELIST = 0xFE7C47895eDb12a990b311Df33B90Cfea1D44c24;

    bytes32 constant MARKET_ID = 0xA597B5A36F6CC0EDE718BA58B2E23F5C747DA810BF8E299022D88123AB03340E;

    UZRLeverage public leverageContract;
    UZRUnwindQuoter public quoter;
    ILendingMarket public lendingMarket;
    IERC20 public busd0;
    IERC20 public usd0;
    IERC20 public rtUsd0;
    MarketParams public marketParams;

    address internal target;
    uint256 internal debt;
    uint256 internal collateral;
    uint256 internal rtBefore;
    uint256 internal usd0Before;

    /// @dev The position owner this suite simulates.
    function _target() internal pure virtual returns (address);

    function setUp() public {
        vm.createSelectFork(RPC_URL, FORK_BLOCK);

        target = _target();
        vm.label(target, "TargetUser");
        vm.label(UZR_LENDING_MARKET, "UZRLendingMarket");
        vm.label(BUSD0, "BUSD0");
        vm.label(USD0, "USD0");
        vm.label(RTUSD0, "rtUSD0");

        lendingMarket = ILendingMarket(UZR_LENDING_MARKET);
        busd0 = IERC20(BUSD0);
        usd0 = IERC20(USD0);
        rtUsd0 = IERC20(RTUSD0);

        marketParams = MarketParams({
            loanToken: USD0,
            collateralToken: BUSD0,
            oracle: ORACLE,
            irm: IRM,
            ltv: 880000000000000000,
            lltv: 999900000000000000,
            whitelist: WHITELIST
        });
        require(Id.unwrap(marketParams.id()) == MARKET_ID, "Market ID mismatch");

        // Deploy a leverage contract owned by the target and authorize it, as the owner would
        leverageContract = new UZRLeverage(target);
        vm.label(address(leverageContract), "UZRLeverage(target)");
        quoter = new UZRUnwindQuoter();

        vm.prank(target);
        lendingMarket.setAuthorization(address(leverageContract), true);

        (,, debt,, collateral) = lendingMarket.getUserPosition(marketParams, target);
        require(debt > 0 && collateral > 0, "target has no position at fork block");
        rtBefore = rtUsd0.balanceOf(target);
        usd0Before = usd0.balanceOf(target);

        console.log("=== Position at fork block", FORK_BLOCK, "===");
        console.log("address              :", target);
        console.log("collateral (bUSD0)   :", _fmt(collateral));
        console.log("debt (USD0)          :", _fmt(debt));
        console.log("equity at par (USD0) :", _fmt(collateral - debt));
        console.log("leverage (x100)      :", (collateral * 100) / (collateral - debt));
        console.log("rt-USD0 held         :", _fmt(rtBefore));
    }

    /// @dev Target acquires `amount` rt-USD0 the canonical way: mint with fresh USD0,
    ///      bUSD0 leg parked on a sink so only the rt reaches the target.
    function _giveTargetRt(uint256 amount) internal {
        address sink = makeAddr("busd0-sink");
        deal(USD0, target, usd0.balanceOf(target) + amount);
        vm.startPrank(target);
        usd0.approve(BUSD0, amount);
        IUsd0PP(BUSD0).mint(amount, sink, target);
        rtUsd0.approve(address(leverageContract), type(uint256).max);
        vm.stopPrank();
    }

    function _logOutcome(string memory route, uint256 proceeds) internal view {
        uint256 parEquity = collateral - debt;
        console.log("---", route, "---");
        console.log("proceeds (USD0)          :", _fmt(proceeds));
        if (proceeds <= parEquity) {
            console.log("loss vs par equity (USD0):", _fmt(parEquity - proceeds));
            console.log("loss vs par equity (bps) :", ((parEquity - proceeds) * 10000) / parEquity);
        }
    }

    /// @dev Integer USD with 2 decimals, e.g. 1115402 = 11154.02
    function _fmt(uint256 wad) internal pure returns (uint256) {
        return wad / 1e16;
    }

    function test_Unwind_PoolExit() public {
        UZRUnwindQuoter.UnwindQuote memory q = quoter.quoteUnleverage(target, type(uint256).max, 0);
        console.log("quoted pool leg out (USD0):", _fmt(q.poolLegOut));
        console.log("quoted proceeds (USD0)    :", _fmt(q.expectedUsd0Out));

        vm.prank(target);
        leverageContract.unleverageFlash(type(uint256).max, 0, false, q.expectedUsd0Out - 2);

        (,, uint256 debtAfter,, uint256 collateralAfter) = lendingMarket.getUserPosition(marketParams, target);
        assertEq(debtAfter, 0, "debt cleared");
        assertEq(collateralAfter, 0, "collateral cleared");

        uint256 proceeds = usd0.balanceOf(target) - usd0Before;
        assertApproxEqAbs(proceeds, q.expectedUsd0Out, 2, "quote matches execution");
        _logOutcome("POOL EXIT (sell collateral at market)", proceeds);
    }

    function test_Unwind_FloorExit() public {
        uint256 floorPrice = IUsd0PP(BUSD0).getFloorPrice();
        console.log("floor price (1e18)        :", floorPrice);

        vm.prank(target);
        leverageContract.unleverageFlash(type(uint256).max, 0, true, 0);

        (,, uint256 debtAfter,,) = lendingMarket.getUserPosition(marketParams, target);
        assertEq(debtAfter, 0, "debt cleared");

        uint256 proceeds = usd0.balanceOf(target) - usd0Before;
        assertApproxEqAbs(proceeds, (collateral * floorPrice) / 1e18 - debt, 2, "floor math");
        _logOutcome("FLOOR EXIT (unlockUsd0ppFloorPrice)", proceeds);
    }

    function test_Unwind_ParExit() public {
        // Hypothetical: target sources rt-USD0 equal to its collateral (e.g. had kept it from
        // minting, or bought it off-pool), then exits entirely at par.
        _giveTargetRt(collateral);
        uint256 usd0Start = usd0.balanceOf(target);

        vm.prank(target);
        leverageContract.unleverageFlash(type(uint256).max, collateral, false, 0);

        (,, uint256 debtAfter,, uint256 collateralAfter) = lendingMarket.getUserPosition(marketParams, target);
        assertEq(debtAfter, 0, "debt cleared");
        assertEq(collateralAfter, 0, "collateral cleared");

        uint256 proceeds = usd0.balanceOf(target) - usd0Start;
        assertApproxEqAbs(proceeds, collateral - debt, 2, "par exit exact");
        assertEq(rtUsd0.balanceOf(target), rtBefore, "only pre-existing rt left");
        _logOutcome("PAR EXIT (reconstruct with rt-USD0)", proceeds);
    }

    /// @notice The headline comparison: same position, three routes, side by side.
    function test_Unwind_CompareAllRoutes() public {
        uint256 parEquity = collateral - debt;

        // 1) pool exit
        uint256 snap = vm.snapshotState();
        vm.prank(target);
        leverageContract.unleverageFlash(type(uint256).max, 0, false, 0);
        uint256 poolProceeds = usd0.balanceOf(target) - usd0Before;
        vm.revertToState(snap);

        // 2) floor exit
        snap = vm.snapshotState();
        vm.prank(target);
        leverageContract.unleverageFlash(type(uint256).max, 0, true, 0);
        uint256 floorProceeds = usd0.balanceOf(target) - usd0Before;
        vm.revertToState(snap);

        // 3) par exit (target sources rt = collateral)
        _giveTargetRt(collateral);
        uint256 usd0Start = usd0.balanceOf(target);
        vm.prank(target);
        leverageContract.unleverageFlash(type(uint256).max, collateral, false, 0);
        uint256 parProceeds = usd0.balanceOf(target) - usd0Start;

        console.log("");
        console.log("=== UNWIND COMPARISON (USD0, 2 decimals as integer) ===");
        console.log("par equity (theoretical max) :", _fmt(parEquity));
        console.log("1. pool exit proceeds        :", _fmt(poolProceeds));
        console.log("2. floor exit proceeds       :", _fmt(floorProceeds));
        console.log("3. par (reconstruct) proceeds:", _fmt(parProceeds));
        console.log("");
        console.log("=== GAIN OF RECONSTRUCT ROUTE ===");
        console.log("vs pool exit (USD0)          :", _fmt(parProceeds - poolProceeds));
        console.log("vs pool exit (bps of equity) :", ((parProceeds - poolProceeds) * 10000) / parEquity);
        console.log("vs floor exit (USD0)         :", _fmt(parProceeds - floorProceeds));
        console.log("vs floor exit (bps of equity):", ((parProceeds - floorProceeds) * 10000) / parEquity);

        assertGt(parProceeds, poolProceeds, "reconstruct beats pool");
        assertGt(parProceeds, floorProceeds, "reconstruct beats floor");
        assertApproxEqAbs(parProceeds, parEquity, 2, "reconstruct is par");
    }
}

/// @notice 0x8926...c14e — 86k bUSD0 collateral, ~7.7x leverage at the fork block.
contract UZRWhaleSimulationForkTest is UZRPositionSimulationBase {
    function _target() internal pure override returns (address) {
        return 0x89261878977B5a01C4fD78Fc11566aBe31BBc14e;
    }
}

/// @notice 0x6564...ca09 — 26.7k bUSD0 collateral, ~6.4x leverage at the fork block.
contract UZRPosition6564SimulationForkTest is UZRPositionSimulationBase {
    function _target() internal pure override returns (address) {
        return 0x6564fC5BF97d95a83dC57a9D525fF63f944bCA09;
    }
}
