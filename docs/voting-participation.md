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

This is a reader anchored to a bundled consensus committee, not a full rotating
light client. The bundled public keys and original voting powers live in
`rust/src/wallet/voting/trust/`. Their hashes must match the original pins below,
which were captured from the official RPCs on 2026-09-10:

| Network | Chain | RPC | Validator-set hash |
| --- | --- | --- | --- |
| main | zvote-1 | https://vote-rpc-primary.valargroup.org | 621A1E2C532170C3C0BC2E951D26C1CCA7A0EFB009AA15820D648D336C64F6BD |
| test | svote-1 | https://stage.vote-rpc-primary.valargroup.org | 6E81F631CB63A527AB5A659529BA8942C46CCF78BA87D1B3AD4CF8AE5BDC2E8B |

The initial trust anchor relies on that official HTTPS bootstrap. The current
validator set must hash to the signed header, but need not hash to the bundled
pin. The same commit must have strictly more than two-thirds signing power under
both the bundled original powers and the current powers. Public-key/address
consistency, duplicate validators/signers and voting-power bounds are checked.
New powers cannot inflate a signer's contribution under the bundled anchor.

This permits limited validator replacement and power changes without more RPCs.
It does not advance the trust anchor or implement a time-bounded rotating light
client. Cumulative changes that lose the bundled >2/3 quorum require a reviewed
anchor update. The original committee remains a long-lived trust assumption;
this does not provide automatic protection against compromise of its retired
keys. Custom sources remain unsupported. Regtest retains its explicit disposable
exact-set anchor. Failed checks remain unknown and never suppress a card.

## Persistence and recovery

A verified result is cached per network/config fingerprint/account/round. Successful
checks are not repeated automatically. Consecutive failures back off for 1, 2, 4,
8, 16, then at most 30 minutes, per network/source/account/round. Existing Home
triggers retry once that deadline passes; no retry timer is added. Backoff lives
only in memory and resets after success. Cancelled work (lock, account or source
change) and incomplete sync do not increase the delay.
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
proof bytes, value, wrong network and stale/future headers. Deterministic signed
headers also cover partial validator replacement, changed powers, both strict
quorum boundaries, forged validator addresses and duplicate signers. No private wallet
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

Home participation work stops at asynchronous boundaries when Home is left or
the app backgrounds. An already dispatched request may finish; subsequent
requests, evaluation and remaining rounds are skipped. A new Home visit gets a
new scope, while explicit detail checks remain independent of Home visibility.
Round details are retained in memory per network/config/account/round only while
waiting for snapshot sync, avoiding repeated detail requests during that wait.
Manual retries fetch fresh details.

Within one participation check, a transient HTTP failure retries only that request
once after 300 ms. Successful responses and the selected proof height are retained.
Permanent HTTP errors, malformed data and failed proof verification are not retried
inside the operation. The four-minute budget and Home cancellation still apply;
a final failure falls back to the coordinator's exponential backoff.

When preparation finds zero snapshot notes, no participation RPC is sent. Rust
rereads the wallet and accepts empty evidence only for the same empty candidate
set. The existing local result/persistence path still runs; zero notes never
means previously used voting rights and does not change Home visibility rules.
