## Phase 0 — Pool discovery and the initial question

After learning about reentrancy attacks in Patrick Collins course I found an [article](https://hackmd.io/@LlamaRisk/BJzSKHNjn) about the Curve's CRV/ETH pools exploit in 2023, which was caused due to the same attack vector that I just learned, so I was curious about testing this new attack technique I learned (in a local fork, of course).
The first thing was to verify the actual state of the pool. The results surprised me. According to the `balances` function in the "Read Contract" section, the internal accounting of `coins(0)` (ETH) was equal to the physical state, but the counterpart, `coins(1)`, reported a corrupted state.

> balances(0) = 33.389 ETH (physical state = accounting state)
> balances(1) = ~1.54 billion CRV (physical state is ~0.019 CRV != 1.54 billion CRV of accounting state)

**Hypothesis:** the first hypothesis that it came to me was to replicate the flash loan to stabilize the state of the pool and then replicate the attack vector used in 2023.

**Where this led:** the internal accounting state was clearly corrupted, yet the pool still responded to the reads. That raised a doubt about if those 33 ETH are still extractable. To find out, I moved to inspecting the pool's functions through Etherscan.


## Phase 1 — Etherscan inspection

Three functions caught my interest: `calc_withdraw_one_coin`, `calc_token_amount` and `get_dy`.
*Note*: All these functions in the "Read Contract" section are fully view and do not always match the results obtained with the ones that actually modify the state of the pool.

* `calc_withdraw_one_coin(uint256 token_amount, uint256 i)`: this function simulates burning `token_amount` LP to withdraw `coins(i)`. Toward ETH the view returned dust for small sizes and reverted at 4 LP. Toward CRV it did NOT revert, in fact, it returned huge values (14,379 CRV for 2 LP). At first this might seem odd as there is no way the pool can give you that amount of CRV when the pool is almost empty of CRV, but it makes sense: the view computes the withdrawal from the corrupted internal accounting (the ~1.54 billion phantom CRV), not the ~0.019 physical CRV. So the view 'works' toward CRV only because it trusts the ghost balance; a real remove_liquidity_one_coin toward CRV would revert against the physical shortage (as Phase 4 later confirms).
  
  >calc_withdraw_one_coin(2000000000000000000, 0) = 314996088520180
  >calc_withdraw_one_coin(4000000000000000000, 0) = Error: Returned error: execution reverted
  >calc_withdraw_one_coin(2000000000000000000, 1) = 14379744294492957112822
  >calc_withdraw_one_coin(4000000000000000000, 1) = 28759421807110292260565

* `calc_token_amount(uint256[2] amounts)`: same logic but with the deposit functionality with an array input of 2 (first for ETH; second for CRV). It will return the amount of LP tokens corresponding to the deposit. I tried to deposit 1 WETH and 1 CRV and it returned 6273 LP tokens, which seemed correct.
  
  >calc_token_amount([1000000000000000000,1000000000000000000]) = 6273891071491852513142

* `get_dy(uint256 i, uint256 j, uint256 dx)`: this one tries to swap the tokens (i = 1 & j = 0, CRV input -> ETH output; i = 0 & j = 1, ETH input -> CRV output) to their counterpart. This function also worked. Note that the ETH -> CRV direction returns an enormous CRV output due to the same reason mentioned in `calc_withdraw_one_coin`, the view trusts the phantom CRV balance.
  >get_dy(1, 0, 10000000000000000000) = 218069771838
  >get_dy(0, 1, 10000000000000000000) = 350235585220832233591714376

**Where this led:** After verifying that the pool isn't frozen or broken, at least through Etherscan, I wanted to do a real test with real tools and compare the results.


## Phase 2 — First test

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

> WETH.balanceOf(pool) = 1e11 wei (dust)
> pool.balance = 33.389e18 wei (the real ETH)

**Where this led:** This confirmed the state of the pool and it's balances. Now it was time to test if it was possible to do a real deposit and withdrawal on a local fork.



The rest is still in progress...