# Entitlements & Quota Policy Contract (v1)

Maintained in lockstep in both repositories:
`Cadenza/docs/entitlements-contract.md` and
`cadenzapp-web/docs/specs/entitlements-contract.md`. The server owns
enforcement (INV-12); the client uses this contract for UI and
upload-switch availability only.

## Error envelope

The standard error envelope is:

```json
{"code": "<stable_code>", "error": "<stable_code>", "message": "optional human text"}
```

`code` is the canonical machine-readable field. `error` carries the
identical value as a backward-compatible alias for clients that predate
`code`; it remains until no supported client reads it, after which only
`code` is contractual. Clients must prefer `code` and may fall back to
`error`.

## Versioning

- `contract_version` identifies the response shape. Current: **1**.
- Additive optional fields do **not** bump the version; removing or
  repurposing a field does.
- A response without `contract_version` is a pre-versioning server
  speaking the original flat shape and is treated as version 1. That
  flat shape's own fields stay required; only fields that never existed
  in it take documented neutral defaults (`text_sync_used` 0,
  `text_sync_unit` recordings, `text_sync_period` none,
  `storage_reserved_bytes` 0, `subscription_status` active — or grace
  when `grace_until` is present, which is what that shape implied).
- A response that explicitly declares version 1 must carry the full v1
  field set; an omission is malformed, never defaulted.
- Explicit versions below 1, negative quotas or measurements, and an
  empty or whitespace-only plan name are malformed (padded names
  normalize; whitespace is never an identifier).
- Known lifecycle and window invariants must hold: `grace` requires
  `grace_until` and `active`/`expired` forbid it; `monthly` requires
  both period bounds with start < end; `none` forbids bounds. Unknown
  lifecycle or period values stay opaque and gate nothing.
- A client receiving a version newer than it supports, or a malformed
  response, treats it as carrying no authority (keeps last-known UI
  state); it never guesses entitlements from an unknown shape.

## Endpoint

`GET /api/v1/me/entitlements` — authenticated, read-only, idempotent.
It authenticates through the same boundary as the sync and upload routes
whose consumption it reports, and answers only for the calling account.

```json
{
  "contract_version": 1,
  "plan": "free",
  "subscription_status": "grace",
  "text_sync_quota": 200,
  "text_sync_used": 13,
  "text_sync_unit": "recordings",
  "text_sync_period": "monthly",
  "text_sync_period_start": 1785542400,
  "text_sync_period_end": 1788220800,
  "audio_upload": false,
  "storage_quota_bytes": 0,
  "used_bytes": 0,
  "storage_reserved_bytes": 0,
  "grace_until": 1788000000
}
```

Two field families with different semantics:

- **Entitlement fields** (`text_sync_quota`, `audio_upload`,
  `storage_quota_bytes`) describe the server's **effective behavior**.
  While enforcement is not rejecting requests, the snapshot is
  allow-all (`null` quotas, `audio_upload: true`) regardless of plan
  configuration, so a client can never disable uploads or surface quota
  pressure that no request would hit. The rollout mode itself is
  server-internal and never serialized.
- **Lifecycle fields** (`subscription_status`, `grace_until`) always
  reflect the subscription state so it round-trips provider-neutrally.

| Field | Semantics |
| --- | --- |
| `plan` | Opaque non-empty plan name; display data, never a client-side gate. |
| `subscription_status` | `active`, `grace`, or `expired`. `grace_until` is present exactly when the status is `grace`. Unknown values must be tolerated. |
| `text_sync_quota` | Max text units in the accounting window. `null` = unlimited. |
| `text_sync_used` | Units counted in the current window, derived from durable state. |
| `text_sync_unit` | What the quota counts: `recordings` or `bytes`. Configuration, so the open rows-versus-bytes product decision is not baked into the contract. |
| `text_sync_period` | `none` (all-time) or `monthly` (current UTC calendar month). |
| `text_sync_period_start` / `text_sync_period_end` | Epoch-second bounds of the current window (end = reset instant); omitted for `none`. The authoritative boundary for period UI. |
| `audio_upload` | Whether audio upload is effectively permitted right now. |
| `storage_quota_bytes` | Max audio storage. `null` = unlimited. |
| `used_bytes` | Committed audio storage consumed. |
| `storage_reserved_bytes` | Bytes reserved by in-flight uploads. Storage admission checks use `used + reserved + request`, so concurrent uploads cannot each pass by ignoring the other. |
| `grace_until` | Epoch seconds. Present exactly while `subscription_status` is `grace`. Grace never re-allows uploads. |

## Subscription lifecycle

`subscription_status` is provider-neutral and moves only between three
states.

- **active** — the account holds what `plan` describes. A payment
  provider reporting a subscription as paid puts the account here on the
  plan it pays for and clears any grace.
- **grace** — the account has lost paid entitlement. `plan` is already
  the deployment default, so the text quota is the one that plan
  describes. Grace is not an entitlement of its own: what it does is
  keep audio already in cloud storage readable until `grace_until`.
- **expired** — the grace deadline has passed, or the account lost a
  subscription without holding paid entitlement to begin with.

New audio upload is refused in both `grace` and `expired`, independently
of the plan. A deployment whose default plan sets `audio_upload: true`
still refuses uploads in those states, and `audio_upload` in the
snapshot reports that same effective answer. Text sync is governed by
the plan alone.

Rules the client can rely on:

- Grace starts once, on the transition out of paid entitlement, and its
  deadline never moves afterwards. A repeated or later provider update
  that is still not paid finds the account already in grace or expired
  and does not change its audio retention. An expired row carrying an
  obsolete plan name may be normalized to the deployment default without
  changing that settled retention state. The deadline is therefore a
  function of the configured length, not of provider traffic.
- Grace starts from any account the server has durably recorded as
  active, whatever plan name that record carries: the record exists only
  because reconciliation wrote it against an authoritative provider
  object, so renaming or retiring a plan in configuration never erases
  the entitlement it describes.
- An account the server never recorded anything for is never put into
  grace by a loss: there is nothing to keep readable for a while. It
  settles durably on the deployment default plan with `expired` and no
  `grace_until`. Existing audio keeps its ordinary retention deadline;
  the post-grace disposition applies only to audio affected by a real
  transition out of paid entitlement. Repeating the event changes
  nothing further.
- Paying again restores `active` on the paid plan and drops
  `grace_until`. When a real paid loss had replaced audio retention, the
  ordinary window is restored; a first payment after a never-paid
  settlement does not rewrite deadlines that never changed. A later,
  independent loss starts a fresh grace measured from that loss.
- Grace ends by its deadline passing. The snapshot reports `expired` and
  omits `grace_until` from that instant on, whether or not the server
  has yet written it down, and quota decisions read the same. A client
  therefore never has to poll for a state change it can compute.
- A subscription that is no longer live never changes the lifecycle of
  an account a different subscription currently holds, whichever order
  the two arrive in.

Audio already in cloud storage stays readable for the whole grace
period, whatever retention window each recording carried before. What
becomes of it afterwards is deployment configuration, one of:

- `retain_read_only` — the audio stays present and readable with no
  deletion deadline. The non-active lifecycle still blocks new uploads.
- `delete` — the audio becomes eligible for the ordinary retention sweep
  once the deadline passes, and `audio_state` moves to `expired` with
  `GET /audio` answering 410 `audio_expired`.

Neither disposition ever removes a transcript, a summary, a recording
row, its key material, its manifest, or anything stored on the device.
Text sync is unaffected by both.

The server keeps an internal origin bit on the durable grant so an
`expired` lifecycle reached after grace remains distinguishable from an
`expired` never-paid settlement. It is not an API field. The distinction
also applies when an upload session admitted earlier commits later: only
the former receives the post-grace audio disposition.

## Usage accounting

`text_sync_used`, `used_bytes`, and `storage_reserved_bytes` are measured
from durable server state when the response is composed. What each one
counts is fixed by this contract, not by a deployment:

- `recordings` counts every recording the account durably stores. Moving
  a recording to trash still stores it, so trash does not release a unit;
  deleting it does.
- `bytes` counts the **plaintext** bytes of the canonical transcript and
  summary artifacts the server stores for those recordings, not their
  encrypted size on disk. A structured sync projects the request into
  those canonical artifacts before measuring, so the number reflects
  what is stored rather than the exact request body.
- The window applies to the server-side instant a recording was first
  stored, never to a client-supplied timestamp, so a device clock cannot
  move usage between windows. Editing a recording re-measures it in place
  and never re-charges it to a later window.
- `used_bytes` counts the plaintext bytes of committed audio the account
  still stores; audio released by retention expiry stops counting.
- `storage_reserved_bytes` counts the declared size of upload sessions
  that could still commit at that instant. A session's bytes move from
  reserved to `used_bytes` in the transaction that commits it, and a
  committed, aborted, or expired session reserves nothing — so a retried
  commit is never counted twice.
- A measurement the server cannot derive from durable state is an error,
  never a zero: the endpoint fails rather than report less than the
  truth, and a client already treats a 5xx as carrying no authority.

## Admission

A write is admitted against the same durable totals the endpoint reports,
at the moment it is stored, and is charged only for what it adds:

- A structured sync that creates a recording is charged one recording, or
  its full canonical stored bytes.
- A structured sync that replaces an existing recording is not another
  recording. The decision is about the total the account is left holding,
  not about a difference: an account already over its quota may still
  replace text with less, and is refused only once the total it would be
  left with does not fit. A recording created in an earlier window is not
  counted in the current one, so replacing its text charges the current
  window nothing.
- An exact replay stores nothing new and is charged nothing, so a client
  retrying a request it already made is never refused for quota, even
  under a plan that has since become restrictive.
- Creating an upload session reserves its declared size once. An
  idempotent replay is answered from the session that already exists,
  before entitlements are re-evaluated, so a plan that changed since
  cannot strand an upload in flight; the session finishes within its TTL,
  and committing it moves the same bytes from reserved to committed
  without charging them again. A replay must repeat every input the
  session was created from; the same key with different inputs is a
  conflict rather than a retry, and leaves the earlier session untouched.
  Keys belong to one account, so two accounts may use the same one.
- A refused write leaves nothing behind: no row, no measurement, and no
  stored artifact. Nothing already stored is removed to make room.

## Rejection codes

Enforcement (when active) rejects with HTTP **403** and the error
envelope above. Clients distinguish causes by code, not status or
message. Codes are append-only; meanings never change and codes are
never reused.

| Code | Emitted by | Client behavior |
| --- | --- | --- |
| `text_quota_exceeded` | `PUT /sync/recordings/{id}` | Stop further text sync for the profile and surface the state. Already-synced content is untouched; the oldest entries are never overwritten. |
| `audio_upload_not_entitled` | upload session create | Disable the audio upload switch surface; text sync continues. |
| `storage_quota_exceeded` | upload session create | Same as above; existing cloud audio is unaffected. |

Codes are machine identifiers, not display strings; clients localize
their own user-facing copy. A blank code is not an identifier: clients
ignore such an envelope instead of surfacing an opaque diagnostic.

## Subscription purchase and management

Two authenticated routes exist only on a deployment where the payment
provider is fully configured; otherwise they are not mounted and answer
404. Both answer with a single short-lived provider URL and nothing
else, and both take no redirect, price, or customer from the request.

`POST /api/v1/billing/checkout` — body
`{"plan":"<configured plan>","idempotency_key":"<caller key>"}`, answer
`{"url":"..."}`. The plan is an internal plan name from the same
configuration the entitlement policy uses; the price it maps to is
server configuration and is never accepted from or returned to the
client. The key is bound to the account and to the plan it first named:
repeating it returns the same purchase, and reusing it for another plan
is a conflict rather than a second purchase. An account holds one open
purchase at a time; a key that expires unpaid releases it, so a new key
can start another.

`POST /api/v1/billing/portal` — empty body, answer `{"url":"..."}`.
Available only to an account that already has a provider customer.

Failures use the same envelope and the same code discipline as the rest
of the contract. Codes are append-only:

| Code | Status | Client behavior |
| --- | --- | --- |
| `unknown_plan` | 400 | The plan is not sold by this deployment; refresh what is on offer. |
| `bad_payload` | 400 | Malformed request, missing or oversized key, or a field the caller may not set. |
| `subscription_exists` | 409 | The account already has a subscription the provider has not reported as finished; send the user to the portal instead. |
| `checkout_in_progress` | 409 | Another key already holds this account's one open purchase; resume that one rather than starting a second. |
| `idempotency_key_conflict` | 409 | The key already names a different purchase; start a new one under a new key. |
| `checkout_unresolved` | 409 | An earlier attempt may already have opened a payment and can no longer be resolved safely, so the server refuses to risk a second one. Not retryable by the client. |
| `checkout_expired` | 409 | The purchase this key opened expired unpaid. The account is free again; start a new one under a new key. |
| `checkout_session_unusable` | 409 | The purchase this key opened can no longer be paid and is not one the server can release on its own — typically it completed and is awaiting reconciliation. Not retryable under the same key. |
| `no_billing_customer` | 409 | The account has never purchased, so there is nothing to manage. |
| `provider_unavailable` | 502 | Transient; retry with the same key. |

A grant is never established by these responses. Entitlements move only
when the provider reports the purchase and the server retrieves the
authoritative subscription, so a client that has just returned from
checkout re-fetches the entitlements endpoint rather than assuming a
plan. Until the provider reports it, the previous snapshot stays
correct.

While a subscription stops being current, the grant it produced is not
withdrawn by this reconciliation: what an account keeps afterwards is
the grace and downgrade decision below, which is still open.

## Idempotency expectations

- The entitlements endpoint is read-only and idempotent.
- Usage derives from durable state (row counts or byte totals, plus
  explicit reservations), never from request counters: retrying an
  idempotent sync upsert (same `client_id`) or an upload commit (same
  session / idempotency key) can never consume quota twice.
- Enforcement decisions are evaluated per request at the enforcement
  point; a request rejected for quota leaves no partial state. A
  reservation taken for an upload is released when the upload aborts or
  expires.
- Policy checks fail closed on corrupt measurements (negative or
  overflowing values); the rollout mode still gates whether that
  verdict rejects anything.

## Official service vs self-host

- The official backend serves the endpoint and (once rollout completes)
  enforces quotas server-side. A 404 from the official service is an
  outage shape: it carries no authority and never grants anything.
- Only a **caller-proven self-hosted origin** may interpret 404 as "the
  endpoint is not implemented here": the client then treats the account
  as fully entitled, because enforcement on a self-hosted deployment is
  that server's own concern. The proof is the client's origin
  classification (its configured backend is not the official origin),
  never the response itself.
- Any other failure (5xx, auth, transport) carries no authority: the
  client keeps its last-known state and retries later.

## Configuration and rollout gating

Commercial values are deployment configuration, never code:

- `CADENZA_ENTITLEMENT_PLANS` — JSON:
  `{"default_plan":"free","plans":{"free":{"text_quota":200,"text_unit":"recordings","text_period":"monthly","audio_upload":false,"storage_quota_bytes":0}}}`.
  `null` quota = unlimited. Unset = a single allow-all plan, so an
  unconfigured deployment applies no quota and rejects no request.
  Parsing is strict: unknown fields and trailing content are
  configuration errors.
- `CADENZA_ENTITLEMENT_ENFORCEMENT` — `off` (default) / `log` /
  `enforce`. `off` evaluates nothing and rejects nothing; `log`
  evaluates and records would-deny verdicts but still allows; `enforce`
  rejects. `enforce` is refused at startup in **production**: a rejected
  request is only safe once a client release handles these codes and can
  show the user why. Other environments may enforce, so the behavior can
  be exercised end to end before that release exists.
- `CADENZA_STRIPE_SECRET_KEY`, `CADENZA_STRIPE_WEBHOOK_SECRET`,
  `CADENZA_STRIPE_PRICES`, `CADENZA_STRIPE_CHECKOUT_SUCCESS_URL`,
  `CADENZA_STRIPE_CHECKOUT_CANCEL_URL`, `CADENZA_STRIPE_PORTAL_RETURN_URL`
  — all or none. A partial configuration is refused at startup rather
  than serving a purchase flow with a missing half. Unset means the
  billing routes are not mounted at all. `CADENZA_STRIPE_PRICES` is
  JSON mapping each internal plan to its provider price
  (`{"pro":"price_..."}`); every plan named must be defined by
  `CADENZA_ENTITLEMENT_PLANS`, the mapping must be one-to-one, and
  parsing is strict. The three URLs are absolute and HTTPS, except that
  a non-production deployment may use HTTP to a loopback host. These
  settings are independent of the enforcement gate above: configuring
  billing never enables quota rejection.
- `CADENZA_ENTITLEMENT_GRACE` — how long grace lasts, as a Go duration
  (`168h`). It must be positive: a downgrade with no grace at all is a
  different policy and is not expressed by this setting.
- `CADENZA_ENTITLEMENT_POST_GRACE_AUDIO` — `retain_read_only` or
  `delete`, exactly. Both are required together wherever billing is
  configured, and startup refuses a billing deployment that is missing
  either: the first account to stop paying would otherwise reach a
  downgrade with no answer for how long it keeps its audio or what
  happens to it. A deployment with billing off needs neither, though a
  value it does supply still has to parse. Neither has a built-in value,
  because both are commercial decisions.
- Grant plan resolution: an empty or whitespace-only plan name takes
  the deployment default, and the response serializes the resolved
  default plan name; a persisted grant naming a plan the policy no
  longer defines resolves **allow-all** with an observable
  `unknown_open` classification and keeps its original name visible —
  configuration drift must never reduce a persisted grant's
  entitlements, and the drift stays loggable.

## Unresolved product values (configuration, not contract)

- Free-tier text quota number and unit (`recordings` vs `bytes` is a
  configured choice; both are first-class in the contract).
- Plan tiers and storage quota sizes.
- The grace length and post-grace audio disposition themselves, and the
  notification cadence around a downgrade. The contract defines what
  each choice means; which one a deployment sells is configuration.
