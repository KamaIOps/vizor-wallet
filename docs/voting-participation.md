# Restored voting participation

Home schedules a client-side check for active, visible candidate rounds after
wallet sync reaches the snapshot. Detail entry also waits for the same deduplicated
check before preparing voting power. The list preview and submission/recovery
jobs do not start another participation check. Home can show its card while the
first check runs. Settings remains a permanent entry point.

Rust reads the account's Orchard full viewing key and snapshot notes. It derives
real-note governance nullifiers with the pinned `zcash_voting` SDK. This works for
UFVK-only Keystone accounts without QR interaction, spending keys, hotkeys, PIR,
or proof generation. Actual voting still uses the existing signer flow.

The Dart client uses the wallet's network HTTP transport, including its Tor policy.
It reads `/commit`, `/validators`, then one `/abci_query` per real note, four at a
time, at the signed header height minus one. Each request has a ten-second timeout;
a check has a four-minute budget and a 1,024-note cap. It does not query Lambda
with account identifiers. A vote RPC can observe and correlate the queried
governance identifiers; this is not private information retrieval. Do not log
query URLs, keys, evidence, or raw transport errors.

## Proof and trust boundary

The Cosmos vote store key is `01 00 || round_id || governance_nullifier`.
Rust verifies IAVL membership (value `01`) or non-membership, then the multistore
proof for `vote` against the signed header's app hash. It checks chain ID, height,
header hash, time (at most ten minutes old or one minute ahead), validator-set
hash and the Tendermint commit's signature quorum. Missing/pruned/invalid proofs
remain unknown and never suppress a card or exclude notes.

This is a pinned consensus committee reader, not a full rotating light client.
Validator hashes were captured from the official RPCs on 2026-09-10:

| Network | Chain | RPC | Validator-set hash |
| --- | --- | --- | --- |
| main | zvote-1 | https://vote-rpc-primary.valargroup.org | 621A1E2C532170C3C0BC2E951D26C1CCA7A0EFB009AA15820D648D336C64F6BD |
| test | svote-1 | https://stage.vote-rpc-primary.valargroup.org | 6E81F631CB63A527AB5A659529BA8942C46CCF78BA87D1B3AD4CF8AE5BDC2E8B |

The initial trust anchor relies on that official HTTPS bootstrap. Committee
rotation requires a reviewed app update with newly authenticated anchors. Never
accept a new committee merely because the current RPC supplies it. Custom voting
config sources and other networks skip this check. These constraints deliberately
produce unknown status rather than accepting unverifiable remote assertions.

## Persistence and recovery

A verified result is cached per network/config fingerprint/account/round. Successful
checks are not repeated automatically; failures have a one-minute retry backoff.
Detail's **Check again** explicitly retries and refreshes eligibility. Rewinding
below the checked snapshot invalidates cached eligibility and participation hints.
This is a restore-time observation, not continuous cross-device monitoring.

Verified used notes are excluded from new eligibility, precomputation and all
software/Keystone delegation preparation paths. The adapter retains the SDK's
selection layout, witness, proof and signing algorithms. The sidecar's
`vizor_voting_participation` table belongs to Vizor and is cleared on account
deletion. Existing bundle plans are never rewritten: local recovery takes
precedence, including when a bundle was concurrently prepared.

If some unused notes still meet the SDK's voting threshold, voting remains
available with that subset. If used notes leave no eligible bundle and there is
no existing local bundle state, Home hides the card and detail explains that
voting cannot be restarted on this device. This means the snapshot voting rights
were used for delegation; it does **not** prove every proposal was voted on.
Lost voting hotkey secrets cannot be recreated from a wallet seed or Keystone UFVK.

All asynchronous checking/persistence registers with the account deletion/reset
drain before its first await. Account/network/source/lock changes cancel results;
queued checks are serialized and concurrent checks for a round share one future.

## Validation

The JSON fixtures in `rust/tests/fixtures/voting-participation` contain public
mainnet/stage signed headers, validator sets, and actual membership/non-membership
proofs. Tests use each fixture header's timestamp, so they remain deterministic.
Corruption tests cover signatures, validator power, app hash, query key/height,
proof bytes, value, wrong network and stale/future headers. No private wallet
material is included.

## Mobile reinstall regtest E2E

Run `scripts/e2e/flutter-ios-regtest-mobile-voting-reinstall.sh` with an explicit
`SIMULATOR_UDID` when multiple simulators are booted. The existing mobile voting
runner now also asserts that a fully completed vote removes its Home card.

The reinstall runner keeps the same Zcash and vote chain alive between two
Flutter integration invocations. Phase one imports, syncs and votes through the
real mobile UI. The host verifies the app is uninstalled after Flutter test cleanup,
explicitly uninstalling it if the Flutter runner leaves it installed. Phase two asserts the old DB/sidecar are absent, clears only
the regtest app's surviving secure storage, and imports the same mnemonic from
birthday 1. No database, voting hotkey, progress or participation cache is copied.

Tests configure transport/source support and the newly created local chain's
trust anchor. They do not override eligibility, participation, Home visibility,
or cryptographic verification. The regtest anchor is immutable for that process
and is never consulted for mainnet/testnet. The gateway relays actual CometBFT
proofs and records aggregate request counts without logging queried identifiers.

The restored Home assertion requires an active round in the actual cached list,
a synced snapshot, verified used notes, no remaining voting rights and no local
recovery state. It then asserts the card is absent, checks Settings/detail access,
and checks that Home reentry does not repeat participation RPCs. Screenshots are
saved under `.regtest-voting/logs/screenshots/`.
