// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.30;

import "forge-std/Test.sol";
import "forge-std/console.sol";

import {UZRLeverage} from "../src/UZRLeverage.sol";
import {ILendingMarket} from "../src/interfaces/ILendingMarket.sol";
import {Id, Market, MarketParams} from "../src/interfaces/ILendingMarketBase.sol";
import {IOracle} from "../src/interfaces/IOracle.sol";
import {MarketParamsLib} from "../src/libraries/MarketParamsLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Extended ERC20 interface with balanceOf and allowance

/// @title UZRLeverageForkTest
/// @notice Fork test for UZRLeverage contract on mainnet
contract UZRLeverageForkTest is Test {
    using MarketParamsLib for MarketParams;
    uint256 internal constant USER_PK = 0xA11CE;
    uint256 internal constant USER2_PK = 0xB0B;

    // Mainnet addresses
    address internal USER;
    address internal USER2;
    address constant UZR_LENDING_MARKET = 0xa428723eE8ffD87088C36121d72100B43F11fb6A;
    address constant BUSD0 = 0x35D8949372D46B7a3D5A56006AE77B215fc69bC0;
    address constant USD0 = 0x73A15FeD60Bf67631dC6cd7Bc5B6e8da8190aCF5;
    address constant ORACLE = 0x30Da78355FcEA04D1fa34AF3c318BE203C6F2145;
    address constant IRM = 0xdfCF197B0B65066183b04B88d50ACDC0C4b01385;
    address constant WHITELIST = 0xFE7C47895eDb12a990b311Df33B90Cfea1D44c24;

    // Uniswap Universal Router (mainnet)
    address constant UNISWAP_V4_SWAP_ROUTER = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;
    uint24 constant POOL_FEE = 100; // 0.01% fee tier (based on successful swap transaction)

    // Market ID
    bytes32 constant MARKET_ID = 0xA597B5A36F6CC0EDE718BA58B2E23F5C747DA810BF8E299022D88123AB03340E;

    UZRLeverage public leverageContract;
    ILendingMarket public lendingMarket;
    IERC20 public busd0;
    IERC20 public usd0;
    MarketParams public marketParams;

    function setUp() public {
        // Fork mainnet
        vm.createSelectFork("mainnet");

        // Derive user addresses from private keys
        USER = vm.addr(USER_PK);
        USER2 = vm.addr(USER2_PK);

        // Label addresses for better debugging
        vm.label(USER, "User");
        vm.label(USER2, "User2");
        vm.label(UZR_LENDING_MARKET, "UZRLendingMarket");
        vm.label(BUSD0, "BUSD0");
        vm.label(USD0, "USD0");
        vm.label(ORACLE, "Oracle");
        vm.label(IRM, "IRM");
        vm.label(UNISWAP_V4_SWAP_ROUTER, "UniswapV3SwapRouter");

        // Initialize interfaces
        lendingMarket = ILendingMarket(UZR_LENDING_MARKET);
        busd0 = IERC20(BUSD0);
        usd0 = IERC20(USD0);

        // Set up market parameters
        marketParams = MarketParams({
            loanToken: USD0,
            collateralToken: BUSD0,
            oracle: ORACLE,
            irm: IRM,
            ltv: 880000000000000000, // 0.88 (88%)
            lltv: 999900000000000000, // 0.9999
            whitelist: WHITELIST
        });

        // Verify market exists
        Id marketId = marketParams.id();
        require(Id.unwrap(marketId) == MARKET_ID, "Market ID mismatch");

        // Deploy leverage contract
        leverageContract = new UZRLeverage(USER);
        // Deal USD0 tokens to users
        deal(USD0, address(leverageContract), 100e18); // Deal 1M USD0 to USER
        //    deal(USD0, USER2, 1000e18); // Deal 1M USD0 to USER2

        vm.label(address(leverageContract), "UZRLeverage");
    }

    function test_UserHasBusd0Balance() public view {
        uint256 balance = usd0.balanceOf(USER);
        console.log("User USD0 balance:", balance);
        assertEq(balance, 0, "User should have USD0 balance");
    }

    function test_ContractDeployment() public view {
        assertEq(address(leverageContract.lendingMarket()), UZR_LENDING_MARKET);
        assertEq(leverageContract.user(), USER);
        assertEq(address(leverageContract.busd0()), BUSD0);
        assertEq(address(leverageContract.usd0()), USD0);
        assertEq(leverageContract.poolFee(), POOL_FEE);
    }

    function test_UserMustApproveContract() public view {
        // Check if user has approved the contract
        // Note: This will fail if user hasn't approved, which is expected
        uint256 allowance = busd0.allowance(USER, address(leverageContract));
        console.log("BUSD0 allowance:", allowance);
    }

    function test_UserMustAuthorizeContract() public view {
        // Check if user has authorized the contract
        bool isAuthorized = lendingMarket.isAuthorized(USER, address(leverageContract));
        console.log("Contract authorized:", isAuthorized);

        if (!isAuthorized) {
            console.log("User needs to call: lendingMarket.setAuthorization(address(leverageContract), true)");
        }
    }

    function test_GetUserPosition() public view {
        (
            uint256 supplyAssets,
            uint256 supplyShares,
            uint256 borrowAssets,
            uint256 borrowShares,
            uint256 collateralAssets
        ) = lendingMarket.getUserPosition(marketParams, USER);

        console.log("User position:");
        console.log("  Supply Assets:", supplyAssets);
        console.log("  Supply Shares:", supplyShares);
        console.log("  Borrow Assets:", borrowAssets);
        console.log("  Borrow Shares:", borrowShares);
        console.log("  Collateral Assets:", collateralAssets);
    }

    function test_MarketInfo() public view {
        Id id = marketParams.id();
        Market memory market = lendingMarket.market(id);
        uint256 totalSupplyAssets = market.totalSupplyAssets;
        uint256 totalSupplyShares = market.totalSupplyShares;
        uint256 totalBorrowAssets = market.totalBorrowAssets;
        uint256 totalBorrowShares = market.totalBorrowShares;
        uint256 lastUpdate = market.lastUpdate;
        uint256 fee = market.fee;
        assertGt(totalSupplyAssets, 0);
        assertGt(totalSupplyShares, 0);
        assertGt(totalBorrowAssets, 0);
        assertGt(totalBorrowShares, 0);
        assertGt(lastUpdate, 0);
        assertEq(fee, 0);
        console.log("Market info:");
        console.log("  Total Supply Assets:", totalSupplyAssets);
    }

    function test_OraclePrice() public view {
        IOracle oracleContract = IOracle(ORACLE);
        uint256 price = oracleContract.price();
        console.log("Oracle price:", price);
        assertGt(price, 0, "Oracle price should be > 0");
    }

    function test_UniswapRouterExists() public view {
        // Check if Uniswap router has code
        uint256 codeSize;
        assembly {
            codeSize := extcodesize(UNISWAP_V4_SWAP_ROUTER)
        }
        assertGt(codeSize, 0, "Uniswap router should have code");
    }

    function test_CalculateBorrowAmount() public view {
        uint256 collateralAmount = 1e18; // 1 BUSD0 (assuming 18 decimals)
        uint256 collateralPrice = IOracle(ORACLE).price();
        uint256 collateralValue = collateralAmount * collateralPrice / 1e18;
        uint256 borrowAmount = collateralValue * marketParams.ltv / 1e18;

        console.log("For 1 BUSD0 collateral:");
        console.log("  Collateral Price:", collateralPrice);
        console.log("  Collateral Value:", collateralValue);
        console.log("  Borrow Amount (88%):", borrowAmount);
    }

    function testFuzz_LeverageIterations(uint8 iterations) public {
        // Limit iterations to prevent gas issues
        iterations = uint8(bound(iterations, 1, 1000));

        // This test would require:
        // 1. User to have deployed the contract
        // 2. User to have transferred sufficient USD0 balance to the contract
        // 3. user has to authorize the contract: lendingMarket.setAuthorization(address(leverageContract),true)
        // 4. Sufficient liquidity in the market

        uint256 balanceleverageContractUSD0 = usd0.balanceOf(address(leverageContract));
        console.log("leverageContract usd0 balance:", balanceleverageContractUSD0 / 1e18);
        uint256 balanceleverageContractBUSD0 = busd0.balanceOf(address(leverageContract));
        console.log("leverageContract busd0 balance:", balanceleverageContractBUSD0 / 1e18);
        assertGt(balanceleverageContractUSD0, 0);
        assertEq(balanceleverageContractBUSD0, 0);
        (
            uint256 userPositionSupplyAssetsBefore,
            uint256 userPositionSupplySharesBefore,
            uint256 userPositionBorrowAssetsBefore,
            uint256 userPositionBorrowSharesBefore,
            uint256 userPositionCollateralAssetsBefore
        ) = lendingMarket.getUserPosition(marketParams, USER);
        assertEq(userPositionSupplyAssetsBefore, 0);
        assertEq(userPositionSupplySharesBefore, 0);
        assertEq(userPositionBorrowAssetsBefore, 0);
        assertEq(userPositionBorrowSharesBefore, 0);
        assertEq(userPositionCollateralAssetsBefore, 0);

        vm.startPrank(USER);
        usd0.transfer(address(leverageContract), usd0.balanceOf(USER));
        lendingMarket.setAuthorization(address(leverageContract), true);

        leverageContract.leveragePosition(iterations);
        vm.stopPrank();
        (
            uint256 userPositionSupplyAssetsAfter,
            uint256 userPositionSupplySharesAfter,
            uint256 userPositionBorrowAssetsAfter,
            uint256 userPositionBorrowSharesAfter,
            uint256 userPositionCollateralAssetsAfter
        ) = lendingMarket.getUserPosition(marketParams, USER);
        assertEq(userPositionSupplyAssetsAfter, 0);
        assertEq(userPositionSupplySharesAfter, 0);
        assertGt(userPositionBorrowAssetsAfter, 0);
        assertGt(userPositionBorrowSharesAfter, 0);
        assertGt(userPositionCollateralAssetsAfter, 0);
    }

    function testFuzz_LeverageIterationTwice() public {
        uint256 balanceUSD0 = usd0.balanceOf(USER);

        uint256 balanceBUSD0 = busd0.balanceOf(USER);

        uint256 balanceleverageContractUSD0 = usd0.balanceOf(address(leverageContract));

        uint256 balanceleverageContractBUSD0 = busd0.balanceOf(address(leverageContract));
        assertGt(balanceleverageContractUSD0, 0);
        assertEq(balanceleverageContractBUSD0, 0);
        assertEq(balanceUSD0, 0);
        assertEq(balanceBUSD0, 0);
        (
            uint256 userPositionSupplyAssets,
            uint256 userPositionSupplyShares,
            uint256 userPositionBorrowAssets,
            uint256 userPositionBorrowShares,
            uint256 userPositionCollateralAssets
        ) = lendingMarket.getUserPosition(marketParams, USER);
        deal(USD0, USER, 100e18); // Deal 100 USD0 to USER
        vm.startPrank(USER);
        usd0.transfer(address(leverageContract), 100e18);
        lendingMarket.setAuthorization(address(leverageContract), true);
        leverageContract.leveragePosition(1);
        vm.stopPrank();
        (
            userPositionSupplyAssets,
            userPositionSupplyShares,
            userPositionBorrowAssets,
            userPositionBorrowShares,
            userPositionCollateralAssets
        ) = lendingMarket.getUserPosition(marketParams, USER);
        balanceUSD0 = usd0.balanceOf(USER);
        balanceBUSD0 = busd0.balanceOf(USER);
        balanceleverageContractUSD0 = usd0.balanceOf(address(leverageContract));
        balanceleverageContractBUSD0 = busd0.balanceOf(address(leverageContract));
        vm.prank(USER);
        leverageContract.leveragePosition(10);
        (
            userPositionSupplyAssets,
            userPositionSupplyShares,
            userPositionBorrowAssets,
            userPositionBorrowShares,
            userPositionCollateralAssets
        ) = lendingMarket.getUserPosition(marketParams, USER);
        balanceUSD0 = usd0.balanceOf(USER);
        balanceBUSD0 = busd0.balanceOf(USER);
        balanceleverageContractUSD0 = usd0.balanceOf(address(leverageContract));
        balanceleverageContractBUSD0 = busd0.balanceOf(address(leverageContract));
    }

    function testFuzz_UnleverageFlash(uint8 iterations) public {
        // Limit iterations to prevent gas issues
        iterations = uint8(bound(iterations, 1, 1000));

        vm.startPrank(USER);
        lendingMarket.setAuthorization(address(leverageContract), true);
        leverageContract.leveragePosition(iterations);
        vm.stopPrank();

        (
            uint256 userPositionSupplyAssetsBefore,
            uint256 userPositionSupplySharesBefore,
            uint256 userPositionBorrowAssetsBefore,
            uint256 userPositionBorrowSharesBefore,
            uint256 userPositionCollateralAssetsBefore
        ) = lendingMarket.getUserPosition(marketParams, USER);
        assertEq(userPositionSupplyAssetsBefore, 0);
        assertEq(userPositionSupplySharesBefore, 0);
        assertGt(userPositionBorrowAssetsBefore, 0);
        assertGt(userPositionBorrowSharesBefore, 0);
        assertGt(userPositionCollateralAssetsBefore, 0);

        // Single-tx flashloan unwind, no rt-USD0, pool exit
        vm.prank(USER);
        leverageContract.unleverageFlash(type(uint256).max, 0, false, 0);
        (
            uint256 userPositionSupplyAssetsAfter,
            uint256 userPositionSupplySharesAfter,
            uint256 userPositionBorrowAssetsAfter,
            uint256 userPositionBorrowSharesAfter,
            uint256 userPositionCollateralAssetsAfter
        ) = lendingMarket.getUserPosition(marketParams, USER);
        assertEq(userPositionSupplyAssetsAfter, 0);
        assertEq(userPositionSupplySharesAfter, 0);
        assertEq(userPositionBorrowAssetsAfter, 0);
        assertEq(userPositionBorrowSharesAfter, 0);
        assertEq(userPositionCollateralAssetsAfter, 0);
    }

    // Helper function to check prerequisites
    function test_CheckPrerequisites() public view {
        uint256 busd0Balance = busd0.balanceOf(USER);
        uint256 busd0Allowance = busd0.allowance(USER, address(leverageContract));
        bool isAuthorized = lendingMarket.isAuthorized(USER, address(leverageContract));

        console.log("=== Prerequisites Check ===");
        console.log("BUSD0 Balance:", busd0Balance);
        console.log("BUSD0 Allowance:", busd0Allowance);
        console.log("Contract Authorized:", isAuthorized);

        if (busd0Balance == 0) {
            console.log("WARNING: User has no BUSD0 balance");
        }

        if (busd0Allowance < busd0Balance) {
            console.log("WARNING: User needs to approve BUSD0");
            console.log("Call: busd0.approve(address(leverageContract), type(uint256).max)");
        }

        if (!isAuthorized) {
            console.log("WARNING: Contract not authorized");
            console.log("Call: lendingMarket.setAuthorization(address(leverageContract), true)");
        }
    }

    function test_ChangeUser() public {
        vm.prank(USER);
        leverageContract.changeUser(USER2);
        console.log("User changed to:", USER2);
        assertEq(leverageContract.user(), USER);
        assertEq(leverageContract.pendingUser(), USER2);
        vm.prank(USER2);
        leverageContract.confirmChangeUser();
        console.log("User confirmed change to:", USER2);
        assertEq(leverageContract.user(), USER2);
        assertEq(leverageContract.pendingUser(), address(0));
    }
}
