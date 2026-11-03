# Blocking and API Failures

- Block only an action that cannot safely proceed without its dependency.
  Explain why, set a timeout, and provide a retry/cancel or recovery path.
- Keep optional requests off critical initialization paths. Failures must not
  lock unrelated controls or show blocking dialogs. Recover in the background
  and display rewards when they become available.
- Retry transient failures with backoff. For unsupported APIs or incompatible
  responses, suspend only that feature and recheck when conditions change.
  Distinguish an unavailable result from a confirmed empty result.
- Cancel requests and retries when their owner exits. Retry writes only when
  repetition is safe; never invent success or duplicate rewards. Refresh affected
  data on recovery and display each reward event once.
- Never synchronously wait on network work on the Unity main thread or server
  event loop. Verify failure followed by recovery, continued play, cancellation,
  and absence of duplicate effects; report unverified runtime cases.
