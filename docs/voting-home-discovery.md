# Mobile Home voting discovery

Home renders the last confirmed account-scoped display decision. Unknown rounds
start hidden. A verified remaining eligible note set or an actionable local
recovery plan confirms visibility; an active round alone does not. Decisions
survive restart and do not depend on the current sync progress height.

Bootstrap reads the local cache, selected source and test-round preference before
Home's first frame. It performs no voting RPC or wallet query for this hydration.
On entry or foreground resume, mainnet with the bundled prod voting source and
testnet with the bundled stage voting source query their public discovery
endpoint once. Network or selected source changes trigger the same check. Concurrent triggers share
one request; a source/network/endpoint switch queues a refresh for the new context.
The one-minute Home timer reevaluates local deadlines without polling discovery.
It also runs the participation candidate scheduler; already checked rounds are
skipped, and unresolved checks respect the participation backoff.

## Build configuration

`VIZOR_VOTING_DISCOVERY_URL` replaces the **entire** discovery endpoint URL.
Its default is `https://functions.vizor.cash/v1/voting/discovery/prod`.
Testnet uses the independent `VIZOR_VOTING_DISCOVERY_STAGE_URL` define, defaulting
to `https://functions.vizor.cash/v1/voting/discovery/stage`.

```sh
fvm flutter run --dart-define=VIZOR_FORM_FACTOR=mobile \
  --dart-define=VIZOR_VOTING_DISCOVERY_URL=https://example.com/v1/voting/discovery/prod
```

The endpoint must use HTTPS (HTTP loopback is accepted for development). This
setting does not change voting config or vote-server URLs. The request uses the
shared network transport's Tor/direct routing policy, with a five-second timeout.
No account identifier or eligibility is sent. Custom voting sources and mismatched
network/source pairs retain direct discovery; an endpoint override does not opt
them in. Prod and stage hints are scoped by both wallet network and config source.

## Refresh and failure behavior

- A valid response has `schemaVersion: 1`, the requested `scope` (`prod` or `stage`), a SHA-256 revision,
  and a UTC `checkedAt`. Reject observations at least ten minutes old and those
  more than one minute ahead of the device clock.
- An unchanged, previously applied revision reuses the list. A missing/changed
  revision runs existing config authentication and authenticated round listing.
  These operations never check Home eligibility or load account recovery/PIR.
- Store the applied revision and endpoint with the successfully refreshed list.
  A probe alone never changes the list's six-hour success timestamp. Existing
  caches without discovery metadata remain readable. Explicit voting-screen
  refreshes preserve the previous applied hint within the same source fingerprint.
- Reconcile via a full refresh at the next Home entry after six hours, even if
  the revision is unchanged. Backend and upstream lists are not an atomic snapshot.
- Probe failures (including 503, stale/invalid responses or URL configuration)
  keep fresh local data and back off for one minute. Missing or expired local
  data still attempts direct discovery. Failed full refreshes back off for five
  minutes and do not save the new revision. No failure means “no votes.”
- Discovery participates in the destructive-operation drain. Discard results
  after lock, source/network/endpoint changes or provider disposal; account
  deletion/reset retain the existing cache cleanup invariants.

Settings keeps its permanent Coinholder voting entry. Actual voting still uses
live config authentication and eligibility checks, irrespective of Home hints.
