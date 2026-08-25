# Research Log — Curve CRV/ETH dead-pool investigation

This is a chronological log of my investigation into whether the ~33 ETH left in the Curve CRV/ETH pool — drained in the 2023 Vyper reentrancy exploit — are still extractable today. 

Unlike the [WRITEUP.md](./WRITEUP.md), which presents the final conclusions in a cleaner way, this research log lays out the whole investigation in a chronological way split into 7 phases where I tell what I was doing, what I measured, what I concluded, and where that led next. It also documents the hypotheses, mistakes, corrections and doubts along the way. I kept all the track of good and bad turns on purpose; they are part of how the conclusions were reached, and they show the reasoning, not just the result.

All tests were done on read-only mainnet forks without modifying the real state of the pool.  
*For the final, structured findings, see [WRITEUP.md](./WRITEUP.md).*

## Phase 0 — Pool discovery and the initial question

While learning about reentrancy attacks in Patrick Collins' "[Smart Contract Security](https://updraft.cyfrin.io/courses/security/puppy-raffle/reentrancy-recap)" course, he shared an [article](https://hackmd.io/@LlamaRisk/BJzSKHNjn) about the 2023 Curve CRV/ETH pool exploit, which was caused due to the same attack vector that I had just learned, so I was curious to test this new technique myself (in a local fork, of course).  

The first thing was to verify the current state of the pool. The results surprised me. According to the contract's `balances` function, the internal accounting of `coins(0)` (ETH) was equal to the physical state, but the counterpart, `coins(1)`, reported a corrupted state.

> balances(0) = ~33.389 ETH (physical state = accounting state)  
> balances(1) = ~1.54 billion CRV (accounting) vs ~0.019 CRV (physical)  

**Hypothesis:** the first hypothesis that came to me was to replicate the flash loan to stabilize the state of the pool and then replicate the attack vector used in 2023.

**Where this led:** the internal accounting state was clearly corrupted, yet the pool still responded to the reads. That raised the question of whether those 33 ETH are still extractable. To find out, I moved to inspecting the pool's functions through Etherscan.


## Phase 1 — Etherscan inspection

Three functions caught my interest: `calc_withdraw_one_coin`, `calc_token_amount` and `get_dy`.
*Note*: All these functions in the "[Read Contract](https://etherscan.io/address/0x8301ae4fc9c624d1d396cbdaa1ed877821d7c511#readContract)" section are fully view and do not always match the results obtained with the ones that actually modify the state of the pool.

* `calc_withdraw_one_coin(uint256 token_amount, uint256 i)`: this function simulates burning `token_amount` LP to withdraw `coins(i)`. Toward ETH the view returned dust for small sizes and reverted at 4 LP. Toward CRV it did NOT revert, in fact, it returned huge values (~14,379 CRV for 2 LP).  
  
  At first this might seem odd as there is no way the pool can give you that amount of CRV when the pool is almost empty of CRV, but it makes sense: the view computes the withdrawal from the corrupted internal accounting (the ~1.54 billion phantom CRV), not the ~0.019 physical CRV. So the view 'works' toward CRV only because it trusts the ghost balance; a real remove_liquidity_one_coin toward CRV would revert against the physical shortage (as [Phase 4](#phase-4--reentrancy-over-mint-curvereentrancyoverminttsol) later confirms).
  
  >calc_withdraw_one_coin(2000000000000000000, 0) = ~0.000315 ETH  
  >calc_withdraw_one_coin(4000000000000000000, 0) = Error: Returned error: execution reverted  
  >calc_withdraw_one_coin(2000000000000000000, 1) = ~14,379 CRV  
  >calc_withdraw_one_coin(4000000000000000000, 1) = ~28,759 CRV  
  
* `calc_token_amount(uint256[2] amounts)`: same logic but with the deposit functionality with an array input of 2 (first for ETH; second for CRV). It will return the amount of LP tokens corresponding to the deposit. I tried to deposit 1 ETH and 1 CRV and it returned 6273 LP tokens, which seemed correct.
  
  >calc_token_amount([1000000000000000000,1000000000000000000]) = ~6,273 LP  

* `get_dy(uint256 i, uint256 j, uint256 dx)`: this one tries to swap the tokens (i = 1 & j = 0, CRV input -> ETH output; i = 0 & j = 1, ETH input -> CRV output) to their counterpart. This function also worked. Note that the ETH -> CRV direction returns an enormous CRV output due to the same reason mentioned in `calc_withdraw_one_coin`, the view trusts the phantom CRV balance.
  >get_dy(1, 0, 10000000000000000000) = ~0.000000218 ETH  
  >get_dy(0, 1, 10000000000000000000) = ~350 septillion CRV (phantom-inflated)  

**Where this led:** after verifying that the pool isn't frozen or broken, at least through Etherscan, I wanted to do a real test with real tools and compare the results.


## Phase 2 — First test: [`CurveDeadPoolProbe.t.sol`](./test/CurveDeadPoolProbe.t.sol)

To see which strategy to follow I decided to make a test to confirm the state of the pool using the state-changing functions behind the view function I used before to get stronger confirmation of that data.  
This test logs:
   - Accounting and physical balances (of ETH, CRV) 
   - Price scale
   - LP total supply
   - D (Invariant: pool’s total liquidity invariant)
   - xp (Effective balances: token balances normalized to a common value scale).

**First measurement (and a mistake):** I read `WETH.balanceOf(pool)` and got
~1e-7 WETH, dust. I wrongly concluded the pool was empty. The confusion came from `coins(0)`, which returns WETH, leading me to check the WETH balance instead of the native ETH.

**Correction:** the pool holds ETH *natively*, not as WETH. Reading `pool.balance` instead returned the real 33.389 ETH. The value was there all along; I had queried the wrong token.

  > WETH.balanceOf(pool) = ~1e-7 WETH (dust)  
  > pool.balance         = ~33.389 ETH (the real value)

**Where this led:** this confirmed the state of the pool and its balances. Now it was time to test if it was possible to do a real deposit and withdrawal on a local fork.


## Phase 3 — Honest baseline: [`CurveNativeEthBaseline.t.sol`](./test/CurveNativeEthBaseline.t.sol)

This is the baseline the reentrancy attack in [Phase 4](#phase-4--reentrancy-over-mint-curvereentrancyoverminttsol) is measured against: if the attack can't beat this, there's no exploit. The test simulates an honest user calling `add_liquidity` and `remove_liquidity_one_coin` (as `remove_liquidity` would revert due to the phantom CRV).  

The resulting data from the deposit confirmed the ~6,273 LP obtained in the `calc_token_amount` view function (in the [Phase 1](#phase-1--etherscan-inspection)) using the same inputs (1 ETH + 1 CRV). Calling `remove_liquidity_one_coin` towards ETH successfully extracted ~0.995 ETH (the missing ~0.0047 ETH were fees) out of the 1 ETH deposited, over 3,136 iterations.

  > add_liquidity{value: 1000000000000000000}([1000000000000000000, 1000000000000000000]) = ~6,273 LP  
  > remove_liquidity_one_coin(2e18, 0, 0, true) x3,136                                    = ~0.995 ETH  

**Interpretation:** honest extraction is capped by the caller's own deposit, you get back slightly less than you deposit (the fees), never more. A legitimate user cannot extract more than what they deposited.

**Where this led:** deposits and withdrawals towards ETH are possible so the next step was to test whether a reentrancy attack could mint more LP than this honest baseline — the 2023 over-mint vector.


## Phase 4 — Reentrancy over-mint: [`CurveReentrancyOvermint.t.sol`](./test/CurveReentrancyOvermint.t.sol)

Through this test the target was to reproduce the over-mint attack and compare it against the ~6,273 LP (obtained in the [Phase 3](#phase-3--honest-baseline-curvenativeethbaselinetsol)) to see if the over-mint is still possible.

### First attempt: `remove_liquidity` and the switch to `remove_liquidity_one_coin`

My first idea was to trigger the reentrancy with `remove_liquidity` but, as it was expected, it reverted: the pool was trying to withdraw more CRV than it physically had, because it didn't exist. Due to that I switched the trigger to `remove_liquidity_one_coin` towards ETH which avoids touching the phantom CRV.  

There is a relevant technical detail between those two functions. `remove_liquidity` updates `self.D` *after* its raw_call — that enabled the over-mint function making the 2023 exploit possible. On the other hand, `remove_liquidity_one_coin` consolidates its `dy` (via `_calc_withdraw_one_coin`) *before* its raw_call closing the opportunity to use the same attack vector as `remove_liquidity`. So the single-coin withdrawal is what lets me fire the reentrancy in the first place, but the over-mint itself would have to come from the reentrant `add_liquidity`, not from the trigger.

### Instrumentation errors

Before running the attack I wanted to review the code carefully so I understood exactly what the code does and spot any mistake. Doing that I caught three bugs:  
  - A missing "}" at the end of an if condition that made part of the code unreachable which I caught by tracing the execution by hand, not after a failed run.  
  - In the `receive()` function there was a bool condition that was preventing any reentry from happening at all. I fixed it so the callback could actually reenter.
  - After initial deposit, the next call reverted for lack of gas. The fix was funding the attack contract with more ETH.  

These bugs show how important it is to make sure that you understand your code as it may not do what you think it does, leading you into wrong assumptions.

### The finding: reentry fires but reverts with "Loss"

**What it first looked like:** at first the test used low-level calls such as `POOL.call` (which will be crucial for the conclusion). The result of the reentrancy attack was an under-mint of ~6,205 LP against the ~6,273 LP obtained in the honest deposit, so there is no way anyone can do an over-mint through `remove_liquidity_one_coin` to extract those ~33 ETH. That result matches with the explanation told before of the `dy` consolidation.

**The correction:** after changing the low-level calls to typed calls and executing it the sequence reverted with `[Revert] Loss`. At first it shocked me because the code and calls were essentially the same but it was all an illusion. Low-level calls do not propagate reverts — they return false and the code goes on — so I was reading values from a state that had actually already reverted, even the under-mint figure was a ghost number from an operation that never persisted.

  > honest deposit mint    = ~6,273 LP  
  > reentrant deposit mint = ~6,205 LP (under-mint, but non-persistent)  
  > full sequence result   = revert "Loss"  

**Conclusion:** reentry fires (`@nonreentrant` still broken) and the reentrant `add_liquidity` computes ~6,205 LP, but `remove_liquidity_one_coin` returns `[Revert] Loss` when consolidating the price so the whole transaction reverts and the attacker is left with nothing — 0 LP, 0 ETH.

**Lesson:** low-level calls that don't check success silently swallow reverts and let you measure fake states that never persisted. It was the switch to typed calls that exposed the truth.  

**Where this led:** the reentrancy vector isn't viable; no transaction persists. That sent me back to the flash loan idea in [Phase 0](#phase-0--pool-discovery-and-the-initial-question) but refined. Instead of using the flash loan to replicate the 2023 attack, what if I used a massive flash loan (especially CRV) to deposit into the pool and to wipe the possibility of revert when using `remove_liquidity` (the function with the real over-mint window). Then do the over-mint, extract my own deposited assets and those ~33 ETH and finally pay back the flash loan with ~33 ETH as profit.


## Phase 5 — Massive flash-loan attack

*Unlike the previous phases, I did not test this one on-chain — I ruled it out by economic reasoning.*  

Everything has to happen in the same transaction — deposit, over-mint, extract and repay. For the idea to work, an enormous amount of CRV is needed to restore the CRV side. Even with that, the pool charges a withdrawal fee proportional to that amount. So knowing that, the main issue is that the withdrawal fee on such a large amount would exceed the ~33 ETH reward available to repay the loan. The flash loan is not profitable in this case. 

**Hypothesis:** as the flash loan idea was invalidated too, the last option I had was to synchronize causing the accounting and physical match so technically `remove_liquidity` would run without reverting, reopening the exact 2023 attack vector — deposit, reenter through the ETH raw_call before `self.D` updates, draining ETH on each iteration. The whole plan hinges on one precondition — being able to sync the pool at all.

**Where this led:** look for a public function that could resync the internal accounting to the physical balances — the precondition for the entire attack.


## Phase 6 — The gulp: [`CurveGulpSync.t.sol`](./test/CurveGulpSync.t.sol)

I had to make sure some sync function existed and I was able to execute it. After searching for it in Etherscan section "[Write Contract](https://etherscan.io/address/0x8301ae4fc9c624d1d396cbdaa1ed877821d7c511#writeContract)", `claim_admin_fees` caught my attention which calls `_claim_admin_fees`. The important part is in the last one which contains:

```python
# Gulp here
    _coins: address[N_COINS] = coins
    for i in range(N_COINS):
        if i == ETH_INDEX:
            self.balances[i] = self.balance
        else:
            self.balances[i] = ERC20(_coins[i]).balanceOf(self)

    vprice: uint256 = self.virtual_price
```  

This for loop syncs both coins overwriting the corrupted accounting `self.balances` with the physical balances fixing the broken state.  
The issue comes after that part:

```python
# Recalculate D b/c we gulped
    D: uint256 = self.newton_D(A_gamma[0], A_gamma[1], self.xp())
    self.D = D

    self.virtual_price = 10**18 * self.get_xcp(D) / total_supply
```  

After synchronizing the balances it recalculates `D` (invariant) and `virtual_price` due to the balance updates — and that's the wall.  
`newton_D` and `virtual_price` updates using the new balances but `total_supply` is still inflated (425,042 LP inherited from the exploit). A little `D` vs a big `total_supply` produces a `virtual_price` that plummets resulting in a revert (probably due to an underflow or an inconsistent division in `newton_D/get_xcp`).
Anyway, that trace got pretty far, read balances, minted fees, emitted `ClaimAdminFee` but reverted in the consolidation with a revert with no message.

  > balances[CRV] before   = ~1.54 billion (accounting) vs ~0.019 (physical)  
  > claim_admin_fees()     = bare EvmError: Revert (no message, unlike the revert "Loss" at [Phase 4](#phase-4--reentrancy-over-mint-curvereentrancyoverminttsol))  
  > balances[CRV] after    = ~1.54 billion (unchanged — the revert undid the gulp)  

**Conclusion:** since the gulp reverts, the pool cannot be synced. This closes the precondition of the whole [Phase 5](#phase-5--massive-flash-loan-attack) attack. Without it, `remove_liquidity` will keep reverting as long as the phantom CRV is not updated, keeping the reentrancy vector closed. The corrupted state of the pool is not just unexploitable, it's unrepairable.


## Closing — a self-sealed pool

Each path that I tried crashed at a wall, each one independent of the others. The only similarity is that all four of them are direct consequences of the 2023 exploit which froze those funds against any reentrancy or similar attack:

1. **Corrupted accounting state:** first finding in [Phase 2](#phase-2--first-test-curvedeadpoolprobetsol). The CRV side keeps a corrupted state: ~1.54 billion CRV (accounting state) vs ~0.019 CRV (physical state).  
2. **Honest extraction is capped:** second finding in [Phase 3](#phase-3--honest-baseline-curvenativeethbaselinetsol). An honest deposit-and-withdrawal can recover at most its own deposit minus fees, so no profit.  
3. **The reentrancy reverts:** third finding in [Phase 4](#phase-4--reentrancy-over-mint-curvereentrancyoverminttsol). Reentrancy still fires, but after switching from low-level calls to typed calls it exposed that the full sequence reverts with Curve's `Loss` guard so no state persists.
4. **Unrepairable state:** fourth finding in [Phase 6](#phase-6--the-gulp-curvegulpsynctsol). Due to the corrupted state of the pool it cannot be gulped or synced (via `claim_admin_fees`), maintaining its broken state.  
   
**Final lesson:** all the investigation came to a simple idea — *a live bug is not the same as a profitable bug*. The miscompiled `@nonreentrant` guard is still broken, but has nothing to do when the post-exploit state is so broken that it disables functions an attacker would need (`remove_liquidity`, `_claim_admin_fees`), making the pool unexploitable and unrepairable.

**Reflection:** as my first investigation I learned a lot about real production contracts and their implications, I'm still a student (almost junior :)) so this was a very hard personal test and I'm very proud of the results. Maybe the last thing I would have liked to check was the flash loan idea in [Phase 5](#phase-5--massive-flash-loan-attack) but I'll leave that for the future. Thanks for taking your time to read about my investigation :).  

*All measurements were taken on read-only mainnet forks pinned to block 25000000, so every number in this log is deterministic and reproducible. For the final, structured findings, see [WRITEUP.md](./WRITEUP.md)*


***:):***