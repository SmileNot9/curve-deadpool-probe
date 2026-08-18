// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test, console2} from "forge-std/Test.sol";

/// @title Curve CRV/ETH honest baseline test.
/// @author SmileNot9
/// @notice Establishes the honest baseline for the dead pool: deposits real
///         liquidity, then drips it back out toward native ETH via
///         remove_liquidity_one_coin. Measures net ETH that a participant can
///         extract, to serve as a reference against the real over-mint attack
///         (see CurveReentrancyOvermint).
/// @dev    Fork test. The pool holds ETH natively, so deposits send
///         msg.value and withdrawals return native ETH.

interface ICurvePool {
    function coins(uint256 i) external view returns (address);
    function add_liquidity(uint256[2] calldata amounts, uint256 min_mint_amount, bool use_eth) external payable returns (uint256);
    function remove_liquidity_one_coin(uint256 token_amount, uint256 i, uint256 min_amount, bool use_eth) external returns (uint256);
}

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

contract CurveNativeEthBaseline is Test {
    /* Constants */
    address constant POOL = 0x8301AE4fc9c624d1D396cbDAa1ed877821D7C511;
    address constant LP_TOKEN = 0xEd4064f376cB8d68F770FB1Ff088a3d0F3FF5c4d;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant CRV = 0xD533a949740bb3306d119CC777fa900bA034cd52;
    uint256 constant I_ETH = 0; // coin 0 = native ETH (registered as WETH in the pool)

    // We declare it as 0 because in a controlled fork test we only
    // care that the call executes so we can measure it, not about slippage.
    // Not safe in production.
    uint256 constant NO_MIN_AMOUNT = 0;

    /* Inmutables */
    ICurvePool immutable pool = ICurvePool(POOL);

    function setUp() public view {
        assertEq(pool.coins(0), WETH, "coins(0) != WETH -> wrong pool");
        assertEq(pool.coins(1), CRV, "coins(1) != CRV  -> wrong pool");
    }

    receive() external payable {} // allow contract to receive native ETH

    /// @notice Deposit real liquidity, then drip it back out toward native ETH
    ///         via remove_liquidity_one_coin. Then shows the results.
    function test_legitimateBaseLine() public {
        uint256 depEth = 1 ether; // 1 ETH
        uint256 depCrv = 1e18; // 1 CRV

        // Fund the test contract for the deposit
        vm.deal(address(this), depEth + 1 ether);
        deal(CRV, address(this), depCrv);
        IERC20(CRV).approve(POOL, type(uint256).max);

        // LP initial balances
        uint256 lpBefore = IERC20(LP_TOKEN).balanceOf(address(this));

        // Real & legitimate ETH deposit
        uint256 lpRet = pool.add_liquidity{value: depEth}([depEth, depCrv], NO_MIN_AMOUNT, true);
        uint256 lpReal = IERC20(LP_TOKEN).balanceOf(address(this)) - lpBefore;

        assertEq(lpRet, lpReal, "return value disagrees with balanceOf delta");
        console2.log("Real minted LP (actual balance):", lpReal);

        // Drip-extraction toward native ETH
        uint256 step = 2e18;
        uint256 ethBeforeLoop = address(this).balance;
        uint256 iter = 0;
        uint256 maxIter = 200_000;

        while (iter < maxIter) {
            uint256 lpHeld = IERC20(LP_TOKEN).balanceOf(address(this));
            if (lpHeld < step) {
                console2.log("LP exhausted at iter:", iter);
                break;
            }
            try pool.remove_liquidity_one_coin(step, I_ETH, NO_MIN_AMOUNT, true) {
                iter++;
            } catch {
                console2.log("remove_liquidity_one_coin REVERTS at iter:", iter);
                break;
            }
        }

        uint256 ethExtracted = address(this).balance - ethBeforeLoop;

        // NET BALANCE
        console2.log("=== RESULT ===");
        console2.log("Iterations completed        :", iter);
        console2.log("ETH extracted (accumulated) :", ethExtracted);
        console2.log("ETH deposited               :", depEth);
        assertLt(ethExtracted, depEth, "honest extraction should never be profitable");
        console2.log("Physical ceiling (ETH in pool):", POOL.balance);
    }
}
