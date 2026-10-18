# Validation and security review notes

This is the implementation contributor's local review, not an independent audit. The network's independent adversarial review and deployment checks remain part of the launch process.

## Recorded validation

The final project was checked with Solidity 0.8.26 and the settings in `foundry.toml`:

| Check | Result |
| --- | --- |
| `forge build` | Passed |
| `forge test` with the assignment's seed | 70 passed, 0 failed, 0 skipped |
| Parameterized fuzz tests | 7 tests, 1,024 cases each |
| Stateful invariant | 128 runs, 64 actions each; 8,192 calls; no handler reverts |
| `forge fmt --check` | Passed |
| Vendored file SHA-256 verification | All 50 source/license files matched |
| Application runtime | 7,525 bytes, below the 24,576-byte EIP-170 limit |
| Application creation bytecode | 9,010 bytes before the one 32-byte constructor argument |
| Runtime instruction scan | No DELEGATECALL, CALLCODE or SELFDESTRUCT outside PUSH data |
| Library references | Fully linked bytecode; no external library placeholders |

The reproducible seed is `0xf99244d597a9e540cf005491c1c502b9182f95e81013e78b343b270e3c46d373`. Tests create isolated local state, set their own chain and time, and use no process environment reads or writes. Test keys and mock token code exist only in `test/`; the launch constructor uses the real owner address given in the brief.

## Test evidence

| Suite | Behaviors checked |
| --- | --- |
| `GameEscrowFlows.t.sol` | Both tokens at minimum, intermediate and maximum stakes; exact deposits and allowances; winner payouts and fractional-unit rounding; draws; both timeout refunds; instant cancellation; access restrictions; all terminal-state transitions; independent concurrent pots |
| `GameEscrowSignatures.t.sol` | Independent EIP-712 encoding; wrong signer, name, version, contract and chain; changed chain ID; modified result fields; expiry and exact deadline; non-player winner; replay and conflicting results; signer rotation; malformed, zero-recovery, high-s and invalid-v signatures |
| `GameEscrowAdmin.t.sol` | Initial parameters and events; fixed owner under CREATE and CREATE2 from a factory; deployment without token code; no escape opcodes; bounds and caps; zero bounds; limits never repricing old matches; pause only blocking new deposits; unauthorized admin calls; absent custody/upgrade methods; direct donations excluded from pots |
| `GameEscrowAdversarial.t.sol` | Short and excess deposits; false-return and no-return tokens; insufficient funds/allowance rollback; failed winner/fee/refund transfers; retry after failure; unrelated matches remaining usable; reentrancy during every lifecycle transfer and across matches |
| `GameEscrowInvariant.t.sol` | Random open, join, settle, cancel, refund, pause, limits and time orderings against a separate state machine and balance ledger; expected successes and expected failures; all public match fields; allowance consumption; per-token conservation; exact fees; refund liveness after each sequence |

The invariant handler catches application reverts and compares them with its predicted validity, so malformed call sequences are exercised without treating all reverts as ignorable. The reported zero **handler** reverts means no model assertion failed; it does not mean invalid application calls succeeded. After every run, time advances beyond all timeouts, every remaining match is refunded, and both escrow token balances must be zero.

## Code review conclusions

- **Custody:** only matched deposits create liabilities. Stored stake and token are immutable for a match. Full match history remains present after closure. No privileged asset transfer, token approval or arbitrary call entry point exists.
- **Reentrancy and atomicity:** every deposit and payout entry point uses the same OpenZeppelin guard. Match effects and lifecycle events precede token interactions. Failed second-leg payments roll back the first transfer and the terminal flag. Signature recovery is a fixed precompile operation, not a server callback.
- **Value conservation:** winner payout is the pot minus the rounded-down fee. Draws and timeouts return the exact stored deposits. Fees are paid only for a successful decisive result, always to the fixed splitter. Hard caps bound arithmetic even after arbitrary valid limit changes.
- **Authorization:** the fixed owner has only signer, limits and pause controls. Neither a factory nor the transaction origin becomes owner. The signer can select only recorded players for decisive payouts, and signature rotation affects pending matches immediately.
- **Replay:** chain ID and contract address separate signing domains. All four result fields are signed. Terminal match IDs are never reused. No per-signer nonce is necessary because the match ID and permanent terminal state consume the result once.
- **Liveness:** A can cancel before joining. Timeout refunds and signed settlement remain available while paused. At each timeout, refund eligibility replaces the join or settlement window. No background automation, owner approval or server response is needed to refund.

Foundry's default lint output includes timestamp comparisons and a conservative `reentrancy-events` warning on `Settled`. The timestamp comparisons implement the requested deadlines and are not randomness. Before `Settled`, the only external operation is ECDSA recovery at the fixed precompile; arbitrary token interactions follow the event, with state already terminal and the reentrancy guard active. The adversarial callback tests confirm this behavior. These lint messages do not fail compilation.

## Operational limits and remaining review

The tests use ERC-20 mocks at the fixed token addresses. They do not establish present mainnet token implementation, token upgrade authority, token availability, fee-splitter behavior, server correctness, key custody or the frontend's game/session binding. No mainnet fork, explorer verification, Slither run or Mythril run was performed. The supplied protected launch harness was read as an input; its manifest-derived deployment environment and imported owner-check implementation are supplied by later launch stages. The local factory and opcode tests rehearse the available deployment criteria without claiming to replace that harness.

The signer is a trusted outcome oracle. A malicious signer can select the wrong participating player, or declare a draw; the contract cannot prove the off-chain game outcome. The owner can rotate that trust. Permissionless IDs and joins require the server to confirm the expected participants before signing. See [integration responsibilities](INTEGRATION.md).

The fixed token contracts are assumed to remain ordinary 18-decimal ERC-20s. Exact incoming balance deltas are checked, but arbitrary rebasing, transfer taxation on outgoing payments or token censorship cannot be repaired by this immutable escrow. Payment failure affects that match and rolls back atomically; independent matches do not share a payout queue. Accidental direct donations have no recovery mechanism by design.

The independent reviewer should verify these custody, authority, timeout and signing assumptions against the approved brief and the eventual launch manifest, then the deployment service should verify the actual deployed constants and bytecode before the application accepts production stakes.
