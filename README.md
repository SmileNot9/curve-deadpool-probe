# Forensic analysis of the Curve CRV/ETH dead-pool

Reproducible forensic analysis of whether the Curve CRV/ETH pool, drained in the July 2023 reentrancy exploit, is still exploitable post-exploit.

## Overview

In 2023 the Curve ETH/CRV pool was drained due to a reentrancy attack caused by a miscompiled Vyper `@nonreentrant` guard bug. This caused an almost full drain of the pool leaving only ~33.38 ETH and ~0.019 CRV. Due to the contract's immutability the bug is still live, so these tests reproduce a similar exploit path and reach the same conclusion: those funds are frozen behind several barriers. *See [WRITEUP.md](./WRITEUP.md) for the full analysis*.

All the work is educational and runs on read-only local forks without modifying the real mainnet.

## Requirements

- [Foundry](https://book.getfoundry.sh/getting-started/installation)
- An Ethereum mainnet RPC (e.g. an Alchemy node)

## Setup

Installation:

```bash
git clone --recurse-submodules https://github.com/SmileNot9/curve-deadpool-probe.git
cd curve-deadpool-probe
forge build
```

If you already cloned without `--recurse-submodules` do:

```bash
git submodule update --init --recursive
```

Provide your RPC endpoint (the `mainnet` alias in `foundry.toml` reads it):

```bash
export MAINNET_RPC="https://eth-mainnet.g.alchemy.com/v2/YOUR_KEY"
```

## Running the tests

The tests run against a mainnet fork pinned to block `25000000` (set in
`foundry.toml`) for deterministic and reproducible results. You only need to export
your RPC endpoint (above).

To run all tests:

```bash
forge test --fork-url mainnet -vvv
```

Or run a single barrier:

```bash
forge test --fork-url mainnet --match-test test_readState -vvv
forge test --fork-url mainnet --match-test test_mapWithdrawBoundary -vvv
forge test --fork-url mainnet --match-test test_legitimateBaseLine -vvv
forge test --fork-url mainnet --match-test test_reentrancyOvermint -vvvv
forge test --fork-url mainnet --match-test test_tryGulpSync -vvvv
```

## Repository structure

The tests are ordered to follow the logical progression of the findings:

| Test file                       | What it demonstrates                                                             |
| ------------------------------- | -------------------------------------------------------------------------------- |
| `CurveDeadPoolProbe.t.sol`      | Barrier 1: corrupted internal state; physical state !=  internal state           |
| `CurveNativeEthBaseline.t.sol`  | Barrier 2: honest extraction is capped by caller's own deposit (no profit)       |
| `CurveReentrancyOvermint.t.sol` | Barrier 3: reentrancy fires but Curve's Loss guard reverts the sequence          |
| `CurveGulpSync.t.sol`           | Barrier 4: synchronization isn't possible and reverts on the consolidation phase |

## Documents

- [WRITEUP.md](./WRITEUP.md) — full forensic analysis & findings.
- [RESEARCH-LOG.md](./RESEARCH-LOG.md) — chronological research log, it includes discarded hypotheses and instrumentation corrections.

## Disclaimer

Educational and defensive security research only. All analysis was performed on
local mainnet forks; no transactions were broadcast to the live network. Nothing
here is financial advice or an invitation to interact with the contract.