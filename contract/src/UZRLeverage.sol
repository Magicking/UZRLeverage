// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.30;

import {IAllowanceTransfer} from "./interfaces/IAllowanceTransfer.sol";
import {ILendingMarket} from "./interfaces/ILendingMarket.sol";
import {MarketParams} from "./interfaces/ILendingMarketBase.sol";
import {IOracle} from "./interfaces/IOracle.sol";
import {IUniswapV3Pool} from "./interfaces/IUniswapV3Pool.sol";
import {IUsd0PP} from "./interfaces/IUsd0PP.sol";
import {ORACLE_PRICE_SCALE} from "./libraries/ConstantsLib.sol";
import {MathLib} from "./libraries/MathLib.sol";
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IUniversalRouter} from "@universal-router/interfaces/IUniversalRouter.sol";
import {Commands} from "@universal-router/libraries/Commands.sol";

/// @title UZRLeverage
/// @notice Contract to leverage a position on UZRLendingMarket and unwind it in a single
///         transaction using the market's free flashloan.
/// @dev Two ways to build the position:
///      - `leveragePosition`: recursive pool-buy loop (bUSD0 bought at market discount, more
///        collateral per USD0, but the discount is paid back when selling on close).
///      - `leverageFlashMint`: single-tx flashloan + `Usd0PP.mint` (1 USD0 -> 1 bUSD0 + 1 rt-USD0
///        at par). The rt-USD0 goes to the user's wallet; holding it makes the later unwind a
///        par exit via `reconstruct`, so the full round trip pays no pool fee or slippage.
///      Unwinding is done with `unleverageFlash`: flashloan USD0, repay debt, withdraw
///      collateral, reconstruct bUSD0 + user's rt-USD0 into USD0 at par, and only market-sell
///      (or floor-price unlock) the remainder.
contract UZRLeverage {
    using SafeERC20 for IERC20;
    using MathLib for uint256;

    /// @notice Permit2 address constant (same on all chains)
    address private _PERMIT2_ADDRESS = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    address constant _UZR_LENDING_MARKET = 0xa428723eE8ffD87088C36121d72100B43F11fb6A;
    address constant _BUSD0 = 0x35D8949372D46B7a3D5A56006AE77B215fc69bC0;
    address constant _USD0 = 0x73A15FeD60Bf67631dC6cd7Bc5B6e8da8190aCF5;
    address constant _RTUSD0 = 0x82DCA22b48B14DE38ccf83B03330120c4b8acFe9;
    address constant _ORACLE = 0x30Da78355FcEA04D1fa34AF3c318BE203C6F2145;
    address constant _IRM = 0xdfCF197B0B65066183b04B88d50ACDC0C4b01385;
    address constant _WHITELIST = 0xFE7C47895eDb12a990b311Df33B90Cfea1D44c24;
    address constant _UNISWAP_V4_SWAP_ROUTER = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;
    /// @notice bUSD0/USD0 Uniswap V3 pool (token0 = bUSD0, token1 = USD0)
    address constant _UNI_V3_POOL = 0xABfCA96716cf2911bBB50A4CDBcBAffA2ef8EcDa;
    uint24 constant _POOL_FEE = 100; // 0.01% fee tier (based on successful swap transaction)
    /// @dev TickMath.MIN_SQRT_RATIO + 1, hardcoded to avoid a v4-core dependency
    uint160 constant _MIN_SQRT_PRICE_LIMIT = 4295128740;

    /// @dev Flashloan callback operations
    uint8 constant _OP_UNLEVERAGE = 0;
    uint8 constant _OP_LEVERAGE_MINT = 1;

    /// @notice Permit2 interface
    IAllowanceTransfer private _PERMIT2 = IAllowanceTransfer(_PERMIT2_ADDRESS);
    IUniversalRouter private _universalRouter = IUniversalRouter(_UNISWAP_V4_SWAP_ROUTER);

    ILendingMarket public immutable lendingMarket = ILendingMarket(_UZR_LENDING_MARKET);
    address public user;
    address public pendingUser;
    MarketParams public marketParams = MarketParams({
        loanToken: _USD0,
        collateralToken: _BUSD0,
        oracle: _ORACLE,
        irm: _IRM,
        ltv: 88e16,
        lltv: 0.9999e18,
        whitelist: _WHITELIST
    });
    IERC20 public immutable busd0 = IERC20(_BUSD0);
    IERC20 public immutable usd0 = IERC20(_USD0);
    IERC20 public immutable rtUsd0 = IERC20(_RTUSD0);
    IOracle public immutable oracle = IOracle(_ORACLE);

    /// @dev Guards flashloan and swap callbacks: only accepted while a flow started here is live
    bool transient _inFlash;

    constructor(address user_) {
        user = user_;

        // Approve lending market to spend tokens (borrow repayments and flashloan pulls)
        busd0.approve(address(lendingMarket), type(uint256).max);
        usd0.approve(address(lendingMarket), type(uint256).max);

        // Approve the bUSD0 (Usd0PP) contract to pull USD0 for `mint`
        usd0.approve(_BUSD0, type(uint256).max);

        // Approve Permit2 to spend tokens (standard ERC20 approval)
        // Permit2 address is the same on all chains: 0x000000000022D473030F116dDEE9F6B43aC78BA3
        busd0.approve(_PERMIT2_ADDRESS, type(uint256).max);
        usd0.approve(_PERMIT2_ADDRESS, type(uint256).max);

        // Set up Permit2 allowances for Universal Router
        // Permit2 requires both ERC20 approval AND a Permit2 allowance with expiration
        // We set expiration to max uint48 (far future) and amount to max uint160 (unlimited)
        uint48 expiration = type(uint48).max; // Far future expiration
        uint160 maxAmount = type(uint160).max; // Unlimited amount

        _PERMIT2.approve(address(busd0), address(_universalRouter), maxAmount, expiration);
        _PERMIT2.approve(address(usd0), address(_universalRouter), maxAmount, expiration);
    }

    /// @notice Leverages the user's position by getting all BUSD0, supplying as collateral, borrowing 88%, swapping,
    /// and repeating @dev IMPORTANT: User must authorize this contract via
    /// lendingMarket.setAuthorization(address(this), true) before calling
    /// @param iterations Number of leverage iterations to perform
    function leveragePosition(uint256 iterations) external {
        // only user can call this function
        require(msg.sender == user, "UZRLeverage: only user can call this function");
        require(iterations > 0, "UZRLeverage: iterations must be > 0");

        // Check authorization
        require(
            lendingMarket.isAuthorized(user, address(this)),
            "UZRLeverage: contract not authorized. Call lendingMarket.setAuthorization(address(this), true)"
        );

        // Swap any existing USD0 to BUSD0 first (if any)
        uint256 usd0Balance = usd0.balanceOf(address(this));
        if (usd0Balance > 0) {
            _swapUsd0ToBusd0(usd0Balance);
        }

        // Get all BUSD0 balance from user
        uint256 busd0Balance = busd0.balanceOf(address(this));
        require(busd0Balance > 0, "UZRLeverage: no BUSD0 balance");

        // Perform leverage iterations
        for (uint256 i = 0; i < iterations; i++) {
            // Get new balance after swap for next iteration
            busd0Balance = busd0.balanceOf(address(this));
            if (busd0Balance <= 1e18) break; // Stop if no more BUSD0
            _leverageIteration(busd0Balance);
        }
    }

    /// @notice Builds the leveraged position in a single transaction by flashloaning USD0 and
    ///         minting bUSD0 at par via Usd0PP.
    /// @dev The contract must hold the user's USD0 equity before the call. `mint` sends the
    ///      bUSD0 leg here (supplied as collateral) and the rt-USD0 leg to the user's wallet.
    ///      Keeping that rt-USD0 lets `unleverageFlash` later exit the same amount at par.
    ///      Trade-off vs `leveragePosition`: minting pays par (no pool discount capture, so less
    ///      collateral per USD0) but the round trip has no pool friction in either direction.
    ///      Reverts after bond maturity (Usd0PP.mint guard).
    /// @param borrowAmount USD0 to flashloan and leave borrowed. Must satisfy the market's LTV:
    ///        borrowAmount <= ltv_target * (equity + borrowAmount); the borrow reverts otherwise.
    function leverageFlashMint(uint256 borrowAmount) external {
        require(msg.sender == user, "UZRLeverage: only user can call this function");
        require(borrowAmount > 0, "UZRLeverage: borrowAmount must be > 0");
        require(lendingMarket.isAuthorized(user, address(this)), "UZRLeverage: contract not authorized");
        require(usd0.balanceOf(address(this)) > 0, "UZRLeverage: no USD0 equity");

        _inFlash = true;
        lendingMarket.flashLoan(_USD0, borrowAmount, abi.encode(_OP_LEVERAGE_MINT, hex""));
        _inFlash = false;
        // The market has pulled the flashloan repayment; nothing should remain, but sweep any
        // rounding dust back to the user.
        uint256 dust = usd0.balanceOf(address(this));
        if (dust > 0) {
            usd0.safeTransfer(user, dust);
        }
    }

    /// @notice Unwinds the position (fully or partially) in a single transaction: flashloan
    ///         USD0, repay debt, withdraw collateral, convert bUSD0 back to USD0, send the
    ///         proceeds to the user.
    /// @dev Conversion is done at par via `Usd0PP.reconstruct` for up to `rtAmount` of the
    ///      user's rt-USD0 (pulled with transferFrom — the user must approve rt-USD0 to this
    ///      contract). Only the remainder is sold: either on the V3 pool (at the market
    ///      discount) or via `unlockUsd0ppFloorPrice` when the floor beats the pool execution
    ///      price. Positions larger than the market's flashloanable USD0 liquidity must be
    ///      unwound in partial chunks by passing `repayAssets` < debt repeatedly.
    ///      If Usd0PP is paused, `reconstruct` reverts — retry with rtAmount = 0.
    /// @param repayAssets USD0 debt to repay; pass type(uint256).max (or >= debt) for a full
    ///        close, which repays by shares and leaves zero debt dust.
    /// @param rtAmount Max rt-USD0 to pull from the user for par reconstruction. Only
    ///        min(rtAmount, withdrawn collateral) is pulled; the excess never leaves the user.
    /// @param useFloorExit If true, dispose of the remainder via the Usd0PP floor price instead
    ///        of the pool. Quote both legs off-chain (see UZRUnwindQuoter) and pick the better.
    /// @param minUsd0Out Minimum total USD0 sent to the user; protects against pool slippage
    ///        and manipulation.
    function unleverageFlash(uint256 repayAssets, uint256 rtAmount, bool useFloorExit, uint256 minUsd0Out) external {
        require(msg.sender == user, "UZRLeverage: only user can call this function");
        require(repayAssets > 0, "UZRLeverage: repayAssets must be > 0");
        require(lendingMarket.isAuthorized(user, address(this)), "UZRLeverage: contract not authorized");

        // Accrue so the borrowAssets read below is exact for this block
        lendingMarket.accrueInterest(marketParams);
        (,, uint256 borrowAssets,,) = lendingMarket.getUserPosition(marketParams, user);
        require(borrowAssets > 0, "UZRLeverage: no debt");

        bool fullClose = repayAssets >= borrowAssets;
        // +1 covers the round-up when repaying the full share balance
        uint256 flashAmount = fullClose ? borrowAssets + 1 : repayAssets;

        _inFlash = true;
        lendingMarket.flashLoan(_USD0, flashAmount, abi.encode(_OP_UNLEVERAGE, abi.encode(fullClose, rtAmount, useFloorExit)));
        _inFlash = false;
        // The market has pulled the flashloan repayment via transferFrom at this point

        uint256 proceeds = usd0.balanceOf(address(this));
        require(proceeds >= minUsd0Out, "UZRLeverage: insufficient output");
        if (proceeds > 0) {
            usd0.safeTransfer(user, proceeds);
        }
    }

    /// @notice Lending market flashloan callback. The market transfers the loan before calling
    ///         this and pulls the repayment via transferFrom after it returns (the constructor's
    ///         USD0 approval covers the pull).
    function onFlashLoan(uint256 assets, bytes calldata data) external {
        require(msg.sender == _UZR_LENDING_MARKET, "UZRLeverage: only lending market");
        require(_inFlash, "UZRLeverage: unsolicited callback");

        (uint8 op, bytes memory opData) = abi.decode(data, (uint8, bytes));
        if (op == _OP_UNLEVERAGE) {
            (bool fullClose, uint256 rtAmount, bool useFloorExit) = abi.decode(opData, (bool, uint256, bool));
            _unwindWithLoan(assets, fullClose, rtAmount, useFloorExit);
        } else {
            _mintAndSupplyWithLoan(assets);
        }
    }

    /// @dev Unleverage leg of the flashloan callback: repay, withdraw, convert bUSD0 to USD0.
    function _unwindWithLoan(uint256 assets, bool fullClose, uint256 rtAmount, bool useFloorExit) internal {
        uint256 withdrawn;
        if (fullClose) {
            (,,, uint256 borrowShares, uint256 collateral) = lendingMarket.getUserPosition(marketParams, user);
            // Repay by shares: clears the debt exactly, no dust
            lendingMarket.repay(marketParams, 0, borrowShares, user, hex"");
            withdrawn = collateral;
        } else {
            lendingMarket.repay(marketParams, assets, 0, user, hex"");
            (,, uint256 borrowAfter,, uint256 collateral) = lendingMarket.getUserPosition(marketParams, user);
            // Interest-aware release: keep enough collateral for the remaining debt at the same
            // 1% safety buffer under the market LTV that leveragePosition borrows at
            uint256 requiredCollateral = borrowAfter.wDivUp(marketParams.ltv - 1e16).mulDivUp(
                ORACLE_PRICE_SCALE, oracle.price()
            );
            require(collateral > requiredCollateral, "UZRLeverage: nothing to withdraw");
            withdrawn = collateral - requiredCollateral;
        }
        lendingMarket.withdrawCollateral(marketParams, withdrawn, user, address(this));

        // 1) Par leg: reconstruct bUSD0 + the user's rt-USD0 into USD0, 1:1, no fee
        uint256 rtUse = rtAmount < withdrawn ? rtAmount : withdrawn;
        if (rtUse > 0) {
            rtUsd0.safeTransferFrom(user, address(this), rtUse);
            IUsd0PP(_BUSD0).reconstruct(rtUse, address(this));
        }

        // 2) Remainder leg: floor-price unlock or direct pool sale
        uint256 remainder = busd0.balanceOf(address(this));
        if (remainder > 0) {
            if (useFloorExit) {
                IUsd0PP(_BUSD0).unlockUsd0ppFloorPrice(remainder);
            } else {
                IUniswapV3Pool(_UNI_V3_POOL).swap(
                    address(this),
                    true, // zeroForOne: bUSD0 (token0) -> USD0 (token1)
                    int256(remainder), // positive = exact input (V3 convention)
                    _MIN_SQRT_PRICE_LIMIT,
                    hex""
                );
            }
        }
        // Slippage is enforced on the total proceeds in unleverageFlash after the loan is repaid
    }

    /// @dev Mint-leverage leg of the flashloan callback: mint bUSD0/rt-USD0 at par, supply, borrow.
    function _mintAndSupplyWithLoan(uint256 assets) internal {
        // Equity already in the contract + the flashloaned USD0
        uint256 totalUsd0 = usd0.balanceOf(address(this));
        // bUSD0 to this contract (collateral), rt-USD0 to the user's wallet (par-exit stock)
        IUsd0PP(_BUSD0).mint(totalUsd0, address(this), user);
        lendingMarket.supplyCollateral(marketParams, totalUsd0, user, hex"");
        // Borrow exactly the flashloan so the market's transferFrom pull is covered.
        // Reverts if it violates the market LTV — that is the position-sizing check.
        lendingMarket.borrow(marketParams, assets, 0, user, address(this));
    }

    /// @notice Uniswap V3 swap callback: pays the pool the input tokens owed
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        require(msg.sender == _UNI_V3_POOL, "UZRLeverage: only pool");
        require(_inFlash, "UZRLeverage: unsolicited callback");
        if (amount0Delta > 0) {
            busd0.safeTransfer(msg.sender, uint256(amount0Delta));
        }
        if (amount1Delta > 0) {
            usd0.safeTransfer(msg.sender, uint256(amount1Delta));
        }
    }

    /// @notice Performs a single leverage iteration: supply collateral, borrow, swap
    /// @param collateralAmount Amount of BUSD0 to supply as collateral
    function _leverageIteration(uint256 collateralAmount) internal {
        // 1. Supply collateral (no authorization needed)
        lendingMarket.supplyCollateral(marketParams, collateralAmount, user, "");

        // 2. Calculate borrow amount (88% of collateral value using LTV)
        uint256 collateralPrice = oracle.price();
        uint256 collateralValue = collateralAmount.mulDivDown(collateralPrice, ORACLE_PRICE_SCALE);
        uint256 borrowAmount = collateralValue.mulDivDown(marketParams.ltv - 1e16, 1e18);

        // Ensure we have liquidity to borrow
        if (borrowAmount <= 1e18) return;
        // 3. Borrow USD0 (requires authorization)
        lendingMarket.borrow(marketParams, borrowAmount, 0, user, address(this));

        // 4. Swap USD0 for BUSD0 on Uniswap
        uint256 usd0Balance = usd0.balanceOf(address(this));
        if (usd0Balance > 0) {
            _swapUsd0ToBusd0(usd0Balance);
        }
    }

    /// @notice Swaps USD0 for BUSD0 on Uniswap Universal Router using Permit2
    /// @param amountIn Amount of USD0 to swap
    /// @dev This function uses V3_SWAP_EXACT_IN with Permit2. When payerIsUser=true, the router
    ///      uses Permit2 to pull tokens from this contract (which must have approved Permit2).
    function _swapUsd0ToBusd0(uint256 amountIn) internal {
        require(amountIn > 0, "UZRLeverage: zero swap amount");

        // Ensure we have enough balance
        uint256 balance = usd0.balanceOf(address(this));
        require(balance >= amountIn, "UZRLeverage: insufficient USD0 balance");

        // Encode the V3 path: tokenIn (20 bytes) + fee (3 bytes) + tokenOut (20 bytes)
        bytes memory path = abi.encodePacked(address(usd0), _POOL_FEE, address(busd0));

        // Encode the input parameters for V3_SWAP_EXACT_IN:
        // recipient (address), amountIn (uint256), amountOutMin (uint256), path (bytes), payerIsUser (bool)
        bytes memory input = abi.encode(
            address(this), // recipient
            amountIn, // amountIn
            amountIn.mulDivDown(995, 1000), // amountMin
            path, // path
            true // payerIsUser (true means router uses Permit2 to pull from this contract)
        );

        // Create commands array with V3_SWAP_EXACT_IN command
        bytes memory commands = abi.encodePacked(uint8(Commands.V3_SWAP_EXACT_IN));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = input;

        // Execute the swap with 5 minute deadline
        // The router will use Permit2 to pull USD0 from this contract
        _universalRouter.execute(commands, inputs, block.timestamp + 300);
    }

    /// @notice Emergency function to withdraw any remaining tokens
    /// @param token Token to withdraw
    /// @param amount Amount to withdraw (0 = all)
    function emergencyWithdraw(address token, uint256 amount) external {
        require(msg.sender == user, "UZRLeverage: only user");
        IERC20 tokenContract = IERC20(token);
        uint256 balance = tokenContract.balanceOf(address(this));
        uint256 withdrawAmount = amount == 0 ? balance : amount;
        require(withdrawAmount <= balance, "UZRLeverage: insufficient balance");
        tokenContract.safeTransfer(user, withdrawAmount);
    }

    /// @notice priviledged function to change the user. Will need a confirmation from the user to change the user.
    function changeUser(address newUser) external {
        require(msg.sender == user, "UZRLeverage: only current user can call this function");
        pendingUser = newUser;
    }

    /// @notice confirm the change of user
    function confirmChangeUser() external {
        require(msg.sender == pendingUser, "UZRLeverage: only pending user can call this function");
        user = pendingUser;
        pendingUser = address(0);
    }

    ///getter for POOL_FEE
    function poolFee() external pure returns (uint24) {
        return _POOL_FEE;
    }
}
