# Gift Card claim outcomes

A claim's transaction lifecycle and a card's availability are separate. Opening
or checking a link does not reserve its funds. Competition is settled by the
chain, not by the order of taps in Vizor.

- Empty history or balance is not proof of a failed broadcast or an external
  claim. Saved bearer links remain in secure storage.
- A server rejection is distinct from an unknown response, but neither proves
  that every server rejected the transaction. Pending and partially submitted
  claims remain protected until every transaction is terminal: expired,
  conflicted with a spend covered by six scanned confirmations, or itself
  covered by six scanned confirmations. Mixed outcomes settle as failed only
  when at least one leg failed.
- A card is labelled `Already claimed` only when all its observed shielded
  outputs have settled spends outside its locally created/recorded claims.
  Unspent top-ups prevent that conclusion. Pending scan ranges limit the
  confirmation height. `sent_notes` plus the local `transactions.created`
  marker identifies transactions eligible for metadata recovery. OVK-recovered
  outgoing notes alone cannot distinguish competitors sharing the card's keys. Each attempt persists the prior
  local transaction IDs before submission, so restart recovery includes failed
  legs and excludes older attempts.
- `Check status` scans without retransmitting. Foreground background recovery
  may retry eligible transactions; confirmed input conflicts are excluded even
  after restart. A cancelled scan cannot produce a completed status check.
- Failed claims return to a `Claim failed` state, not an unconditional `Claim`.
  A new claim always prepares again. Settling a transaction compares the recorded
  attempt before writing so a late check cannot overwrite a newer submission.
  Manual/background checks serialize; recovery skips live submissions.
- Only active claims count toward account-deletion protection. A settled failed
  claim clears the destination binding while retaining the bearer link. Hiding
  a card changes only its visibility; archived cards can be restored. Active
  claims cannot be hidden.

The stored Gift Card format is unreleased. Availability and archive fields are
part of the current format; no migration from earlier experimental records is
provided. This change does not resolve the separate sender-side ambiguous draft
export/account-deletion flow.

## Validation

Unit/widget coverage includes conflict finality, incomplete scans, top-ups,
local receipt identity, reorgs, stale checks, secret retention, archive/restore,
read-only status checks, partial submissions, and desktop/mobile outcomes.
Capture scenarios: `gift-card-claimed-elsewhere`, `gift-card-claim-failed`, and
`gift-card-claim-checking` (both form factors).

The explicit two-wallet competition scenario is compiled by:

```sh
cargo test --manifest-path rust/Cargo.toml --test regtest_payment_link_competition --no-run
```

Run it only when regtest execution is explicitly requested (it uses the shared
Docker regtest services and mines blocks):

```sh
cargo test --manifest-path rust/Cargo.toml --test regtest_payment_link_competition -- --ignored --nocapture --test-threads=1
```
