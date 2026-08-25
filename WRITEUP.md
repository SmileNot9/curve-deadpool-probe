# Curve CRV/ETH dead-pool: Is the Residual ETH Still Exploitable?
## Summary  

After the Vyper reentrancy exploit in 2023, the `@nonreentrant` guard is still broken, so the reentrancy bug is still in the immutable bytecode. The remaining funds are still there — ~33 ETH & ~0.019 CRV. This writeup explains why and how those funds are not reachable by the same or similar exploit. The 2023 exploit left a corrupted pool state in the CRV side — ~1.54 billion CRV (accounting) vs ~0.019 CRV (physical) — leaving the pool in an unexploitable and unrepairable state, sealed by four independent barriers.  


## Background

In 2023 [Curve's CRV/ETH pool](https://etherscan.io/address/0x8301ae4fc9c624d1d396cbdaa1ed877821d7c511#code) suffered an exploit draining almost the entire pool: 7,193,401.77 CRV (~$5.1m at time of exploit), 7,680.49 WETH (~$14.2m) and 2,879.65 ETH (~$5.4m). That left the pool with only ~33 ETH and ~0.019 CRV, barely dust. This exploit was caused by a Vyper compiler bug. In a nutshell, the compiler failed to assign the correct reentrancy lock slot, so the `@nonreentrant` guard didn't actually work.


## Pool state

The current pool state:  
  
| Field           | Value         |
| --------------- | ------------- |
| Accounting      |               |
| └─ ETH          | ~33.389       |
| └─ CRV          | ~1.54 billion |
| Physical        |               |
| └─ ETH          | ~33.389       |
| └─ CRV          | ~0.019        |
| Total LP supply | 425,042       |
| D               | ~3,338.9      |
| price_scale     | ~5.28e-5      |
  
*Note: the ETH value is held natively (pool.balance); the WETH token balance is dust (~1e-7)*


## Findings: the four barriers

This investigation found four independent barriers:

### Barrier 1 — Corrupted accounting state

**Claim.** The pool's internal state is corrupted: `balances(1)` (the accounting side of CRV) claims to hold eight orders of magnitude more than physically exists. Any function that reads the corrupted side operates on false data.  

**Mechanism.** After the 2023 exploit the physical CRV was drained but `self.balances(1)` wasn't updated correctly. Due to that, when you check the CRV side (`balances()` for accounting & `balanceOf` for physical) both sides don't match at all — ~1.54 billion CRV (accounting) vs only ~0.019 CRV (physical). Meanwhile, the ETH side (`balances()` for accounting & `balance` for physical) does match as it wasn't corrupted by the exploit.  

**Evidence.** `test_readState`, which reads the pool state, is in `CurveDeadPoolProbe.t.sol`. Running it shows the pool's state:  

> balances(0) (accounting)   = ~33.389 ETH  
> balances(1)  (accounting)  = ~1.54 billion CRV  
> pool.balance (native ETH)  = ~33.389 ETH  
> CRV physical (balanceOf)   = ~0.019 CRV  
> WETH token (balanceOf)     = ~1e-7 WETH  

The test asserts balances(1) > physicalCRV × 100,000, and that native ETH matches accounting while the WETH token is dust.  

**Implication.** Because the accounting side is detached from reality every state-changing function that touches the accounting CRV reverts when it collides with the physical side, while read functions show non-existent values. This is the root cause of the other three barriers as some of them rely on this phantom CRV.  


### Barrier 2 — Honest extraction is capped

**Claim.** An honest user cannot extract more ETH than they deposited themselves. There is no profit.  

**Mechanism.** After adding 1 ETH + 1 CRV through `add_liquidity` it returned 6,273 LP tokens which were then redeemed for ETH firing `remove_liquidity_one_coin` towards ETH in very small iterations (large single withdrawals revert). The test resulted in a return of ~0.995 ETH meaning there is no profit in an honest baseline.  

**Evidence.** `test_legitimateBaseLine`, which performs an honest deposit and withdrawal, is in `CurveNativeEthBaseline.t.sol`. Recovered data shows:   

> ETH deposited         = 1 ETH  
> minted LP             = ~6,273 LP  
> iterations completed  = 3,136  
> ETH extracted         = ~0.995 ETH  

*Net result: loss of ~0.0047 ETH in fees*  

The test asserts `ethExtracted` < `ethDeposited` — honest extraction isn't profitable.  

**Implication.** An honest user cannot obtain any profit by legitimate deposit and withdrawal. This collected data will be compared against reentrancy ([Barrier 3](#barrier-3--the-reentrancy-fires-but-reverts)) to conclude if the attack is profitable or not.  


### Barrier 3 — The reentrancy fires but reverts

**Claim.** The 2023 reentrancy vector still fires, but cannot complete the full sequence due to Curve's `Loss` guard which causes the revert leaving the attacker with nothing.  

**Mechanism.** The attacker fires `add_liquidity` to add some legitimate funds and then triggers `remove_liquidity_one_coin` toward ETH. Inside that function resides a `raw_call` which delegates the flow to the attacker's `receive()` which reenters `add_liquidity`, computing a fresh LP amount mid-withdrawal. But when the outer `remove_liquidity_one_coin` finishes and consolidates the price via `tweak_price`, it fires Curve's `Loss` guard (the recomputed `virtual_price`
falls against the inflated `total_supply`) reverting the whole transaction.  

**Evidence.** `test_reentrancyOvermint`, which performs a reentrancy, is in `CurveReentrancyOvermint.t.sol`. The test shows the following results:  

> initial ETH (physical)  = ~33.39 ETH  
> LP total supply         = ~425,042 LP  
> sequence result         = Attack sequence reverted. Reason: Loss  

*Note: Honest and reentrant LP mint can be read from -vvvv trace.*  

The reentrant deposit gets an under-mint compared to the honest one — ~6,205 LP vs ~6,273 LP — but full sequence reverts with `Loss` guard so no persistent state remains.  

**Implication.** The whole sequence doesn't persist even while `@nonreentrant` is still broken and even if it computed it would produce an under-mint, so no profit here.  


### Barrier 4 — Unrepairable state

**Claim.** The corrupted state of the pool cannot be repaired through the contract's own mechanisms. The only function that could sync it — `claim_admin_fees`, which overrides `self.balances`, reverts at the consolidation phase.  

**Mechanism.** `claim_admin_fees` calls `_claim_admin_fees`, which contains a gulp that overrides `self.balances` with the physical balances (`pool.balance` for ETH; `balanceOf` for CRV). This part succeeds. But after that gulp, the function recomputes `D` and `virtual_price` with the recomputed balances where a little amount of assets (~33 ETH & ~0.019 CRV) collides with an inflated `total_supply` (~425,042 LP) inherited from the exploit which reverts, failing the whole sync.  

**Evidence.** `test_tryGulpSync`, which tries a sync, is in `CurveGulpSync.t.sol`. The test results:  

> balances(1) before  = ~1.54 billion CRV  
> claim_admin_fees()  = EvmError: Revert  (executes: reads balances, mints fees, emits ClaimAdminFee then reverts)
> balances(1) after   = ~1.54 billion CRV (the revert undid the gulp)

The whole sequence reverts with a simple revert without any message (probably an underflow or an inconsistent division in `newton_D/get_xcp`). This failed state is confirmed with the assertEq which compares `balances(1)` before and after the `claim_admin_fees()`.  

**Implication.** Since the pool cannot be synced, it confirms the unrepairable state of the pool and its unexploitability leaving the pool with four independent barriers that prevent the extraction of those 33 ETH.


## Discarded path: the massive flash loan

*Unlike the other paths this one wasn't tested on-chain, I just ruled it out by economic reasoning.*  

The idea was simple: take a flash loan of CRV to fix the corrupted CRV side and unlock `remove_liquidity` so the 2023 reentrancy attack would work again. But the amount of CRV that would be needed does not compensate for the reward — 33 ETH — because the withdrawal fees scales proportionally to the borrowed CRV.  


## Conclusion

Four barriers converge on the same conclusion: the pool is self-sealed, no illegitimate extraction is possible. The valuable lesson here is that a live bug does not always equal an exploitable bug — the `@nonreentrant` guard is still broken, but as we have just seen, the consequences of the 2023 exploit resulted in an unrepairable corrupted state of the pool making those 33 ETH unextractable.  


## Reproducibility

All findings are verified by fork tests pinned at block 25000000 for deterministic results. To run them check [README.md](./README.md) or execute:  

```bash
export MAINNET_RPC="https://..."  
forge test --fork-url mainnet -vvv  
```  

For the full chronological investigation, see [RESEARCH-LOG.md](./RESEARCH-LOG.md).    


## References

- [LlamaRisk post-mortem](https://hackmd.io/@LlamaRisk/BJzSKHNjn)  
- Pool contract: [Etherscan](https://etherscan.io/address/0x8301ae4fc9c624d1d396cbdaa1ed877821d7c511#readContract)  
- Exploit transaction: [Etherscan](https://etherscan.io/tx/0x2e7dc8b2fb7e25fd00ed9565dcc0ad4546363171d5e00f196d48103983ae477c)  
