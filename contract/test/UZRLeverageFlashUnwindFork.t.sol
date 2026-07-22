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

/// @title UZRLeverageFlashUnwindForkTest
/// @notice Mainnet fork tests for the flashloan unwind (unleverageFlash) and the
///         mint-based leverage (leverageFlashMint) paths.
contract UZRLeverageFlashUnwindForkTest is Test {
    using MarketParamsLib for MarketParams;

    // Public gateway also used by the sibling usual-rt-arb repo's fork tests
    string constant RPC_URL = "https://mainnet.gateway.tenderly.co/49LPuZlg4TTIBIZohMSsqL";
    uint256 constant FORK_BLOCK = 25544764;

    uint256 internal constant USER_PK = 0xA11CE;

    address internal USER;
    address internal SINK; // receives unwanted bUSD0 legs when minting rt for tests
    address constant UZR_LENDING_MARKET = 0xa428723eE8ffD87088C36121d72100B43F11fb6A;
    address constant BUSD0 = 0x35D8949372D46B7a3D5A56006AE77B215fc69bC0;
    address constant USD0 = 0x73A15FeD60Bf67631dC6cd7Bc5B6e8da8190aCF5;
    address constant RTUSD0 = 0x82DCA22b48B14DE38ccf83B03330120c4b8acFe9;
    address constant ORACLE = 0x30Da78355FcEA04D1fa34AF3c318BE203C6F2145;
    address constant IRM = 0xdfCF197B0B65066183b04B88d50ACDC0C4b01385;
    address constant WHITELIST = 0xFE7C47895eDb12a990b311Df33B90Cfea1D44c24;
    address constant UNI_V3_POOL = 0xABfCA96716cf2911bBB50A4CDBcBAffA2ef8EcDa;

    bytes32 constant MARKET_ID = 0xA597B5A36F6CC0EDE718BA58B2E23F5C747DA810BF8E299022D88123AB03340E;

    UZRLeverage public leverageContract;
    UZRUnwindQuoter public quoter;
    ILendingMarket public lendingMarket;
    IERC20 public busd0;
    IERC20 public usd0;
    IERC20 public rtUsd0;
    MarketParams public marketParams;

    function setUp() public {
        vm.createSelectFork(RPC_URL, FORK_BLOCK);

        USER = vm.addr(USER_PK);
        SINK = makeAddr("sink");

        vm.label(USER, "User");
        vm.label(UZR_LENDING_MARKET, "UZRLendingMarket");
        vm.label(BUSD0, "BUSD0");
        vm.label(USD0, "USD0");
        vm.label(RTUSD0, "rtUSD0");
        vm.label(UNI_V3_POOL, "BUSD0/USD0-pool");

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

        leverageContract = new UZRLeverage(USER);
        vm.label(address(leverageContract), "UZRLeverage");
        quoter = new UZRUnwindQuoter();
        vm.label(address(quoter), "UZRUnwindQuoter");

        vm.prank(USER);
        lendingMarket.setAuthorization(address(leverageContract), true);
    }

    /*//////////////////////////////////////////////////////////////
                              Helpers
    //////////////////////////////////////////////////////////////*/

    /// @dev Builds a leveraged position via the pool-buy loop with `equity` USD0.
    function _buildPoolPosition(uint256 equity) internal returns (uint256 debt, uint256 collateral) {
        deal(USD0, address(leverageContract), equity);
        vm.startPrank(USER);
        leverageContract.leveragePosition(15);
        // Sweep the unsupplied bUSD0 the loop leaves behind so the unwind starts from a
        // clean contract balance and proceeds can be checked against the market position.
        leverageContract.emergencyWithdraw(BUSD0, 0);
        vm.stopPrank();
        (,, debt,, collateral) = lendingMarket.getUserPosition(marketParams, USER);
        assertGt(debt, 0);
        assertGt(collateral, 0);
    }

    /// @dev Mints `amount` rt-USD0 to USER (the bUSD0 leg goes to SINK) and approves it
    ///      to the leverage contract.
    function _giveRt(uint256 amount) internal {
        deal(USD0, USER, amount);
        vm.startPrank(USER);
        usd0.approve(BUSD0, amount);
        IUsd0PP(BUSD0).mint(amount, SINK, USER);
        rtUsd0.approve(address(leverageContract), type(uint256).max);
        vm.stopPrank();
    }

    function _position() internal view returns (uint256 debt, uint256 shares, uint256 collateral) {
        (,, debt, shares, collateral) = lendingMarket.getUserPosition(marketParams, USER);
    }

    /*//////////////////////////////////////////////////////////////
                          Full unwind flows
    //////////////////////////////////////////////////////////////*/

    function test_FullUnwind_FullRt() public {
        (uint256 debt, uint256 collateral) = _buildPoolPosition(100e18);
        _giveRt(collateral + 1e18);
        uint256 rtBefore = rtUsd0.balanceOf(USER);

        vm.prank(USER);
        leverageContract.unleverageFlash(type(uint256).max, collateral + 1e18, false, 0);

        (uint256 debtAfter, uint256 sharesAfter, uint256 collateralAfter) = _position();
        assertEq(debtAfter, 0, "debt cleared");
        assertEq(sharesAfter, 0, "shares cleared");
        assertEq(collateralAfter, 0, "collateral cleared");

        // Par exit: proceeds == collateral - debt (up to flashloan rounding)
        uint256 proceeds = usd0.balanceOf(USER);
        assertApproxEqAbs(proceeds, collateral - debt, 2, "par proceeds");

        // Only `collateral` rt was pulled; the surplus stayed with the user
        assertEq(rtBefore - rtUsd0.balanceOf(USER), collateral, "rt consumed == collateral");

        // Nothing stranded in the contract
        assertEq(usd0.balanceOf(address(leverageContract)), 0);
        assertEq(busd0.balanceOf(address(leverageContract)), 0);
        assertEq(rtUsd0.balanceOf(address(leverageContract)), 0);
    }

    function test_FullUnwind_NoRt() public {
        (uint256 debt, uint256 collateral) = _buildPoolPosition(100e18);

        UZRUnwindQuoter.UnwindQuote memory q = quoter.quoteUnleverage(USER, type(uint256).max, 0);

        vm.prank(USER);
        leverageContract.unleverageFlash(type(uint256).max, 0, false, 0);

        (uint256 debtAfter, uint256 sharesAfter, uint256 collateralAfter) = _position();
        assertEq(debtAfter, 0, "debt cleared (old path left dust)");
        assertEq(sharesAfter, 0);
        assertEq(collateralAfter, 0);

        // Pool exit: proceeds below par because bUSD0 sells at a discount
        uint256 proceeds = usd0.balanceOf(USER);
        assertLt(proceeds, collateral - debt, "pool exit below par");
        assertGt(proceeds, 0);
        // Quoter called on identical state must match execution
        assertApproxEqAbs(proceeds, q.expectedUsd0Out, 2, "quoter matches execution");
    }

    function test_FullUnwind_PartialRt() public {
        (uint256 debt, uint256 collateral) = _buildPoolPosition(100e18);
        uint256 rtAmount = collateral / 2;
        _giveRt(rtAmount);

        vm.prank(USER);
        leverageContract.unleverageFlash(type(uint256).max, rtAmount, false, 0);

        (uint256 debtAfter,, uint256 collateralAfter) = _position();
        assertEq(debtAfter, 0);
        assertEq(collateralAfter, 0);

        // Between pure-pool and pure-par outcomes
        uint256 proceeds = usd0.balanceOf(USER);
        assertLt(proceeds, collateral - debt + 2);
        assertEq(rtUsd0.balanceOf(USER), 0, "all supplied rt consumed");
    }

    function test_ParBeatsPoolExit() public {
        (, uint256 collateral) = _buildPoolPosition(100e18);
        _giveRt(collateral);

        uint256 snap = vm.snapshotState();
        vm.prank(USER);
        leverageContract.unleverageFlash(type(uint256).max, collateral, false, 0);
        uint256 parProceeds = usd0.balanceOf(USER);

        vm.revertToState(snap);
        vm.prank(USER);
        leverageContract.unleverageFlash(type(uint256).max, 0, false, 0);
        // rt route was not used: user still holds the rt, plus pool proceeds
        uint256 poolProceeds = usd0.balanceOf(USER);

        console.log("par proceeds:", parProceeds);
        console.log("pool proceeds:", poolProceeds);
        assertGt(parProceeds, poolProceeds, "reconstruct beats market sell");
    }

    function test_FloorExit() public {
        (uint256 debt, uint256 collateral) = _buildPoolPosition(100e18);
        uint256 floorPrice = IUsd0PP(BUSD0).getFloorPrice();
        assertGt(floorPrice, 0, "floor set on fork");

        vm.prank(USER);
        leverageContract.unleverageFlash(type(uint256).max, 0, true, 0);

        (uint256 debtAfter,, uint256 collateralAfter) = _position();
        assertEq(debtAfter, 0);
        assertEq(collateralAfter, 0);

        uint256 proceeds = usd0.balanceOf(USER);
        // collateral * floor - debt, up to rounding
        assertApproxEqAbs(proceeds, (collateral * floorPrice) / 1e18 - debt, 2, "floor-price proceeds");
    }

    /*//////////////////////////////////////////////////////////////
                          Partial unwind
    //////////////////////////////////////////////////////////////*/

    function testFuzz_PartialUnwind(uint256 repayAssets) public {
        (uint256 debt,) = _buildPoolPosition(100e18);
        repayAssets = bound(repayAssets, 2e18, debt / 2);

        vm.prank(USER);
        leverageContract.unleverageFlash(repayAssets, 0, false, 0);

        (uint256 debtAfter,, uint256 collateralAfter) = _position();
        assertApproxEqAbs(debtAfter, debt - repayAssets, 1, "debt reduced by repayAssets");
        assertGt(collateralAfter, 0);

        // Remaining position keeps the 1% buffer under the market LTV
        uint256 collateralValue = (collateralAfter * IOracleLike(ORACLE).price()) / 1e36;
        assertLe(debtAfter, (collateralValue * 87e16) / 1e18 + 1, "position within 87% of collateral value");
    }

    /*//////////////////////////////////////////////////////////////
                        Mint-based leverage
    //////////////////////////////////////////////////////////////*/

    function test_LeverageFlashMint() public {
        uint256 equity = 100e18;
        uint256 borrowAmount = 600e18; // 7x total exposure, inside the 87% target
        deal(USD0, address(leverageContract), equity);

        vm.prank(USER);
        leverageContract.leverageFlashMint(borrowAmount);

        (uint256 debt,, uint256 collateral) = _position();
        assertEq(collateral, equity + borrowAmount, "collateral = minted par amount");
        assertApproxEqAbs(debt, borrowAmount, 1, "debt = flashloan");
        assertEq(rtUsd0.balanceOf(USER), equity + borrowAmount, "user stockpiles rt 1:1");
        assertEq(usd0.balanceOf(address(leverageContract)), 0, "no stranded USD0");
    }

    function test_MintThenParUnwind() public {
        uint256 equity = 100e18;
        uint256 borrowAmount = 600e18;
        deal(USD0, address(leverageContract), equity);

        vm.startPrank(USER);
        leverageContract.leverageFlashMint(borrowAmount);
        rtUsd0.approve(address(leverageContract), type(uint256).max);
        leverageContract.unleverageFlash(type(uint256).max, type(uint256).max, false, 0);
        vm.stopPrank();

        (uint256 debtAfter,, uint256 collateralAfter) = _position();
        assertEq(debtAfter, 0);
        assertEq(collateralAfter, 0);
        // Full round trip at par: the user gets their equity back minus only rounding dust
        assertApproxEqAbs(usd0.balanceOf(USER), equity, 3, "round trip loses ~nothing");
        assertEq(rtUsd0.balanceOf(USER), 0, "all rt consumed");
    }

    function test_LeverageFlashMint_OverLtvReverts() public {
        deal(USD0, address(leverageContract), 100e18);
        vm.prank(USER);
        vm.expectRevert();
        leverageContract.leverageFlashMint(900e18); // 90% of total: above market LTV
    }

    /*//////////////////////////////////////////////////////////////
                              Quoter
    //////////////////////////////////////////////////////////////*/

    function test_QuoterPartialRtMatchesExecution() public {
        (, uint256 collateral) = _buildPoolPosition(100e18);
        uint256 rtAmount = collateral / 3;
        _giveRt(rtAmount);

        UZRUnwindQuoter.UnwindQuote memory q = quoter.quoteUnleverage(USER, type(uint256).max, rtAmount);
        assertEq(q.rtUsed, rtAmount);
        assertEq(q.collateralWithdrawn, collateral);
        assertFalse(q.preferFloor, "pool beats 0.92 floor at current tick");

        vm.prank(USER);
        leverageContract.unleverageFlash(type(uint256).max, rtAmount, false, q.expectedUsd0Out - 2);
        assertApproxEqAbs(usd0.balanceOf(USER), q.expectedUsd0Out, 2, "quote == execution");
    }

    function test_QuoteLeverageSwap() public view {
        // 100 USD0 buys more than 100 bUSD0 (discount) but less than 105 (sanity)
        uint256 out = quoter.quoteLeverageSwap(100e18);
        assertGt(out, 100e18);
        assertLt(out, 105e18);
    }

    /*//////////////////////////////////////////////////////////////
                              Guards
    //////////////////////////////////////////////////////////////*/

    function test_OnlyUser() public {
        vm.expectRevert("UZRLeverage: only user can call this function");
        leverageContract.unleverageFlash(1e18, 0, false, 0);
        vm.expectRevert("UZRLeverage: only user can call this function");
        leverageContract.leverageFlashMint(1e18);
    }

    function test_MinOutReverts() public {
        _buildPoolPosition(100e18);
        vm.prank(USER);
        vm.expectRevert("UZRLeverage: insufficient output");
        leverageContract.unleverageFlash(type(uint256).max, 0, false, type(uint256).max);
    }

    function test_OnFlashLoanOnlyMarket() public {
        vm.expectRevert("UZRLeverage: only lending market");
        leverageContract.onFlashLoan(1e18, abi.encode(uint8(0), abi.encode(true, uint256(0), false)));
    }

    function test_UnsolicitedCallbackReverts() public {
        vm.prank(UZR_LENDING_MARKET);
        vm.expectRevert("UZRLeverage: unsolicited callback");
        leverageContract.onFlashLoan(1e18, abi.encode(uint8(0), abi.encode(true, uint256(0), false)));
    }

    function test_SwapCallbackOnlyPool() public {
        vm.expectRevert("UZRLeverage: only pool");
        leverageContract.uniswapV3SwapCallback(1, 1, hex"");
    }

    function test_SwapCallbackUnsolicitedReverts() public {
        vm.prank(UNI_V3_POOL);
        vm.expectRevert("UZRLeverage: unsolicited callback");
        leverageContract.uniswapV3SwapCallback(1, 1, hex"");
    }
}

interface IOracleLike {
    function price() external view returns (uint256);
}
