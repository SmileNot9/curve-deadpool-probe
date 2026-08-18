// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test, console2} from "forge-std/Test.sol";

/// @title Curve CRV/ETH gulp/sync probe.
/// @author SmileNot9
/// @notice Tests the synchronization of the corrupted pool's state
///         to match the physical and accounting state.
/// @dev    Fork test.

interface ICurvePool {
    function balances(uint256 i) external view returns (uint256);
}

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
}

contract CurveGulpSync is Test {
    /* Constants */
    address constant POOL = 0x8301AE4fc9c624d1D396cbDAa1ed877821D7C511;
    address constant CRV = 0xD533a949740bb3306d119CC777fa900bA034cd52;
    uint256 constant I_CRV = 1;

    /* Immutables */
    ICurvePool immutable pool = ICurvePool(POOL);

    /// @notice Attempts to sync the pool's internal accounting state with the physical state.
    function test_tryGulpSync() public {
        console2.log("=== BEFORE ===");
        uint256 crvInternalBefore = pool.balances(I_CRV);
        uint256 crvPhysical = IERC20(CRV).balanceOf(POOL);
        console2.log("balances[CRV] (accounting state)  :", crvInternalBefore);
        console2.log("Physical CRV in pool              :", crvPhysical);

        // Attempt to sync the pool's internal accounting state with the physical state.
        // It's a low-level call so we can capture the revert reason instead of failing the test.
        (bool ok, bytes memory ret) = POOL.call(abi.encodeWithSignature("claim_admin_fees()"));
        console2.log("claim_admin_fees() success:", ok);
        if (!ok) _logRevert("claim_admin_fees()", ret);

        console2.log("=== AFTER ===");
        uint256 crvInternalAfter = pool.balances(I_CRV);
        console2.log("balances[CRV] (accounting state) :", crvInternalAfter);

        if (crvInternalAfter < crvInternalBefore) {
            console2.log(">>> GULP WORKED: accounting state is synced with physical state.");
            console2.log(">>> Now remove_liquidity may not revert.");
            console2.log(">>> new balances[CRV]:", crvInternalAfter);
        } else {
            console2.log(">>> No change: the gulp didn't work.");
            console2.log(">>> The ghost state remains intact.");
        }
        assertEq(crvInternalAfter, crvInternalBefore, "unexpected: gulp changed the CRV accounting");
    }

    function _logRevert(string memory fn, bytes memory ret) internal pure {
        console2.log("  -> revert:", fn);
        if (ret.length >= 68) {
            bytes memory reason = new bytes(ret.length - 68);
            for (uint256 i = 0; i < reason.length; i++) {
                reason[i] = ret[i + 68];
            }
            console2.log("  -> reason:", string(reason));
        } else if (ret.length == 0) {
            console2.log("  -> (no data: reverts without reason)");
        } else {
            console2.log("  -> (no standard revert format -vvvv)");
        }
    }
}
