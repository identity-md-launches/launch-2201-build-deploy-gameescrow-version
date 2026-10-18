# Server and frontend integration

GameEscrow authorizes results using EIP-712 typed data. It verifies standard 65-byte ECDSA signatures (`r || s || v`, with `v` equal to 27 or 28), rejects high-`s` signatures, and requires recovery to the current nonzero `signer()`. ERC-1271 contract signatures and compact 64-byte signatures are not supported. The server signing key is an EOA; the owner's launch address is the initial signer as required by the brief.

The canonical result type string is exactly:

```text
Result(bytes32 matchId,address winner,bool draw,uint256 deadline)
```

Use the following schema with the server's existing typed-data signing library. These variables must come from the confirmed deployment and verified match; they are not configuration defaults:

```javascript
const domain = {
  name: "NightshiftGames",
  version: "2",
  chainId: 1,
  verifyingContract: confirmedGameEscrowAddress,
};
const types = {
  Result: [
    { name: "matchId", type: "bytes32" },
    { name: "winner", type: "address" },
    { name: "draw", type: "bool" },
    { name: "deadline", type: "uint256" },
  ],
};
const message = { matchId, winner, draw, deadline };
// Sign typed data using the current signer. Do not personal_sign the digest.
// Relay: escrow.settle(matchId, winner, draw, deadline, signature).
```

The `deadline` is a Unix timestamp in **seconds**, encoded as a uint256 (use bigint or a decimal string in libraries requiring one). `matchId` and `game` are full bytes32 values; a short game label such as `chess` can be UTF-8 bytes padded on the right. For a draw, the backend can consistently use player A as the ignored winner field to avoid optional-address handling.

`DOMAIN_SEPARATOR()` exposes the separator and `hashResult(matchId, winner, draw, deadline)` exposes the exact final digest. `eip712Domain()` provides EIP-5267 introspection. The contract derives the current chain ID; a signature for a different chain or another GameEscrow instance is invalid. The version is `2`, not v1's domain.

The signature digest is:

```text
domain = keccak256(abi.encode(
    keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
    keccak256("NightshiftGames"), keccak256("2"), chainId, verifyingContract
))
result = keccak256(abi.encode(RESULT_TYPEHASH, matchId, winner, draw, deadline))
digest = keccak256(0x1901 || domain || result)
```

Do not include `game`, token, stake or the players in the signed struct: that would produce a different type hash. Instead, the backend must read the immutable match snapshot and bind it to the authenticated game session **before signing**. Results must only be issued for confirmed joined matches, with the expected players, token, amount, game label and chain. Anyone can open a chosen ID or join an unjoined match; there is no on-chain reserved opponent or matchmaking access list. Use unpredictable unique IDs and reject unexpected on-chain participants at the game layer. A lobby creator can cancel an unjoined match immediately; joined matches fall back to the 24-hour refund if the server refuses to produce a result.

Never pre-sign results for unused or unjoined IDs. The signature schema intentionally follows the requested four fields; it has no separate player signatures or game nonce. The permanent match record and terminal flag provide replay protection. Signing two conflicting results for one match permits whichever is mined first to win; the backend must issue one authoritative outcome and keep an auditable result record.

Choose a short result deadline that leaves enough time for confirmation before `joinedAt + 86400`. Settlement requires both `timestamp <= deadline` and `timestamp < joinedAt + 86400`. Timestamp-based deadlines use the chain's time, not a browser clock. If submission fails due to a transient token transfer failure, the signature remains unused and may be retried while still valid.

Frontends should read `limits(token)` before approving and opening, handle limit changes between estimation and mining, display exact base-unit amounts and the fee formula, and approve only the intended stake when practical. Read the stored match before joining; changing current limits does not change its deposit requirement. For direct API callers there is no `join(matchId, stake)` overload.

Watch terminal events as well as `matches(id).settled`. `Settled` with a draw reports one player's refund in `payout`, so the total token outflow is twice that field. `Cancelled` and `Refunded` are also terminal. A successful terminal transaction cannot be reversed through administration or reused with a new result.
