# Mobile Home voting discovery

Home renders its local round list and account eligibility/completion hints first.
On entry or foreground resume, production builds using the bundled production
voting source query the public discovery endpoint once. Concurrent triggers share
one request; a source/network/endpoint switch queues a refresh for the new context.
The one-minute Home timer only reevaluates local deadlines and does not poll.

## Build configuration

`VIZOR_VOTING_DISCOVERY_URL` replaces the **entire** discovery endpoint URL.
The default is `https://functions.vizor.cash/v1/voting/discovery/prod`.

```sh
fvm flutter run --dart-define=VIZOR_FORM_FACTOR=mobile \
  --dart-define=VIZOR_VOTING_DISCOVERY_URL=https://example.com/v1/voting/discovery/prod
```

The endpoint must use HTTPS (HTTP loopback is accepted for development). This
setting does not change voting config or vote-server URLs. The request uses the
shared network transport's Tor/direct routing policy, with a five-second timeout.
No account identifier or eligibility is sent. Stage/custom voting sources retain
the existing direct discovery path; overriding this URL does not opt them in.

## Refresh and failure behavior

- A valid response has `schemaVersion: 1`, `scope: "prod"`, a SHA-256 revision,
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
