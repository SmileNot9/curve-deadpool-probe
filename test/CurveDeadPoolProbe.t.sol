// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test, console2} from "forge-std/Test.sol";

/// @title  Curve CRV/ETH dead-pool state probe
/// @author SmileNot9
/// @notice Read-only inspection of the CRV/ETH cryptoswap v2 pool drained in the
///         2023 reentrancy exploit. Confirms the corrupted internal accounting
///         and maps the single-coin withdrawal convergence boundary.
/// @dev    Fork test. Run against a mainnet fork; no state is modified.
///         Reference state measured at block 25000000 (pool dormant since
///         the 2023 exploit, so any recent block yields the same values):
///             coins(0) = WETH, coins(1) = CRV
///             balances(0) ~ 33.389e18       (matches native 33.389 ETH held)
///             WETH.balanceOf(pool) ~ 1e11   (dust; real value is native ETH, not the token)
///             balances(1) ~ 1.538e27        (phantom CRV; physical CRV ~ 0.019)
///             D() ~ 3338.9,  price_scale() ~ 5.28e-5,  LP totalSupply ~ 425,042e18

interface ICurvePool {
    function balances(uint256 i) external view returns (uint256);
    function coins(uint256 i) external view returns (address);
    function D() external view returns (uint256);
    function price_scale() external view returns (uint256);
    function calc_withdraw_one_coin(uint256 token_amount, uint256 i) external view returns (uint256);
}

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function totalSupply() external view returns (uint256);
}

contract CurveDeadPoolProbe is Test {
    /* Constants */
    address constant POOL = 0x8301AE4fc9c624d1D396cbDAa1ed877821D7C511;
    address constant LP_TOKEN = 0xEd4064f376cB8d68F770FB1Ff088a3d0F3FF5c4d;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant CRV = 0xD533a949740bb3306d119CC777fa900bA034cd52;
    uint256 constant I_WETH = 0;
    uint256 constant I_CRV = 1;

    /* Immutables */
    ICurvePool immutable pool = ICurvePool(POOL);

    // We make sure the pool uses the expected coins
    function setUp() public view {
        address c0 = pool.coins(0);
        address c1 = pool.coins(1);
        assertEq(c0, WETH, "coins(0) != WETH -> POOL address isn't right, check it");
        assertEq(c1, CRV, "coins(1) != CRV  -> POOL address isn't right, check it");
    }

    /// @notice Read and print the main pool state variables
    /// @dev    It's a view call, so no LP token is required.
    function test_readState() public view {
        // Internal accounting state
        uint256 balanceWeth = pool.balances(I_WETH);
        uint256 balanceCrv = pool.balances(I_CRV);

        // Physical state (actual balance)
        uint256 lpSupply = IERC20(LP_TOKEN).totalSupply();
        uint256 physicalWeth = IERC20(WETH).balanceOf(POOL);
        uint256 physicalCrv = IERC20(CRV).balanceOf(POOL);

        uint256 d = pool.D();
        uint256 ps = pool.price_scale();

        console2.log("=== Initial pool state ===");
        console2.log("balance[WETH] (accounting state)  :", balanceWeth);
        console2.log("balance[CRV]  (accounting state)  :", balanceCrv);
        console2.log("WETH (actual balance)             :", physicalWeth);
        console2.log("CRV  (actual balance)             :", physicalCrv);
        console2.log("D()                               :", d);
        console2.log("price_scale()                     :", ps);
        console2.log("LP total_supply                   :", lpSupply);

        uint256 xp1 = (balanceCrv * ps) / 1e18;

        console2.log("xp[WETH]                          :", balanceWeth);
        console2.log("xp[CRV] (=balanceCrv*ps/1e18)     :", xp1);
        if (balanceWeth > 0) {
            console2.log("ratio xp[CRV]/xp[WETH]        :", xp1 / balanceWeth);
        }

        assertGt(balanceCrv, physicalCrv * 100_000, ">>> Accounting CRV balance is corrupted.");
    }

    /// @notice Maps the convergence boundary for single-coin withdrawal of WETH from the pool.
    /// @dev    It's a view call, so no LP token is required. As the pool is corrupted, the function
    ///         may revert if a large ammount of LP is burned.
    function test_mapWithdrawBoundary() public view {
        console2.log("=== calc_withdraw_one_coin(size LP -> WETH) boundary ===");
        uint256[8] memory sizes = [uint256(1e18), 2e18, 3e18, 4e18, 5e18, 10e18, 100e18, 1000e18];
        for (uint256 k = 0; k < sizes.length; k++) {
            try pool.calc_withdraw_one_coin(sizes[k], I_WETH) returns (uint256 out) {
                console2.log("LP burned / WETH out :", sizes[k], out);
            } catch {
                console2.log("LP burned -> REVERT :", sizes[k]);
            }
        }
    }
}
