# API Failure and Compatibility

Follow these rules when adding or changing API calls, initialization, loading
screens, error UI, or client/server contracts in any module.

## Keep unrelated play available

- Before implementing a request, identify which user action actually needs its
  result. Rewards, friends, announcements, and optional profile decorations
  must not gate lobby initialization, deck loading, matching, or an active game.
- Start optional requests independently of the critical initialization path.
  A hidden popup is insufficient if its awaited request still blocks that path.
- On failure, retain valid cached data when safe, or hide/disable only the
  unavailable feature. Distinguish unavailable data from a confirmed empty
  result; never replace a failed reward lookup with a zero balance.
- Do not show a modal, lock unrelated buttons, pause gameplay, or leave a loading
  overlay active while an optional request retries. Show an inline status only
  where it helps the player use that feature. Notify when a recovered result
  actually requires attention, such as newly received rewards.
- Block only the action that cannot safely proceed without authoritative data:
  authentication, a validated match allocation, spending currency, or committing
  a reward claim. Give that action a bounded wait and a usable retry/cancel path.
  Stop the whole session only when authentication, the authoritative game
  contract, or another verified global prerequisite makes continued play unsafe.

## Recover without retry storms or duplicate effects

- Give requests timeouts. Retry transient network errors and service failures
  in the background with backoff, a maximum interval, and jitter where needed.
  Respect Retry-After. Keep one in-flight request/retry loop per operation.
- A 404 alone does not prove an unsupported API. Distinguish a missing resource
  from a missing route using the endpoint contract and available capability or
  version information. Do not rapidly retry 404/405 or invalid response schemas;
  suspend that optional feature and recheck at a low frequency or on a relevant
  event, such as reconnect, a new session, or capability refresh.
- Handle 401 through the shared authentication recovery flow; do not create
  independent refresh loops. Do not automatically retry permission failures or
  invalid requests until their cause changes.
- Cancel requests and retry loops when their scene, view, session, or owner is
  disposed. Discard responses from a previous user or session. Avoid duplicate
  loops on scene re-entry and retrying against UI that no longer exists.
- Retry state-changing requests only when the server contract makes repetition
  safe (for example, an idempotency key or a query that reconciles the result).
  Reward synchronization may write data even when its name sounds like a read.
  Never assume a timeout means a claim, purchase, or reward grant did not happen.
- On recovery, refresh affected caches and views and display each reward event
  once. Keep the server authoritative for grants, balances, and claim status;
  never fabricate success or mark an unknown result as consumed locally.

## Support deployment differences

- Allow old and new client/server versions to coexist during rollout. Prefer
  additive contracts and explicit feature capabilities; enable optional UI only
  when its required contract is available. Do not infer deployment from a merge.
- Tolerate unknown optional fields or enum values without discarding unrelated
  valid data. Validate required gameplay data before using it; do not continue
  an authoritative game with invented defaults or an incompatible protocol.
- Preserve meaningful HTTP status codes and structured error information on
  the server. Do not turn expected 4xx failures into catch-all 500 responses.
- Log enough sanitized context to diagnose a failing endpoint and recovery.
  Rate-limit repeated identical failures; never expose tokens or private data.

## Verify failure and recovery

For changed API flows, verify the relevant cases: missing endpoint, malformed
or incompatible response, timeout/offline state, authentication expiry, scene
exit during retry, and failure followed by success. Confirm unrelated play stays
available, the affected action has a usable exit, no duplicate request loops or
reward effects occur, and recovered data is presented. Use focused automated
checks where practical and state which runtime scenarios remain unverified.
