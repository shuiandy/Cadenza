# Data and privacy

This document describes Cadenza's technical data flow so users and contributors can see
which features stay on the Mac and which features can send data elsewhere. It is not a
legal privacy policy. Anyone distributing a build or operating a connected service must
publish disclosures appropriate to that distribution and jurisdiction.

## Default behavior

- Recordings, transcripts, summaries, speaker data, chat history, and meeting metadata are
  stored locally.
- Meeting detection and automatic recording are both off by default. Cadenza evaluates
  local meeting signals only after the user enables detection, and it does not start a
  recording until automatic recording is enabled or the user starts one manually.
- The microphone is optional and off by default. Permission is requested only from a
  user-initiated recording or settings action.
- Cloud providers, web sync, exports, and the MCP server require explicit configuration.
- Cadenza does not include an advertising, product-analytics, or crash-reporting SDK.

## Local storage and credentials

The active profile's SwiftData database stores recording metadata, transcripts, summaries,
speaker information, tags, and generated artifacts. Audio and crash-recovery segments are
stored in the selected recordings directory. At startup, Cadenza automatically creates a
consistent SQLite recovery backup for the active profile and keeps at most three automatic
backups in that profile's `Backups` directory. The backup is a single database file with
committed WAL content folded into it; it can therefore contain older recording metadata,
transcripts, summaries, speaker information, and generated artifacts. Portable archives are
created only through their corresponding settings or export flows. An upgraded installation
can also retain pre-profile automatic backups in the legacy `Cadenza-Backups` directory.
Backup creation, rotation, and clearing share one process-wide execution lease. This prevents
races within one running app instance; it is not a cross-process filesystem lock. If the app
exits during backup creation, the next backup attempt immediately removes controlled
incomplete staging artifacts before creating a new snapshot.

API keys, OAuth tokens, and MCP bearer tokens are stored through the macOS Keychain rather
than in the database or portable archive. MCP credentials are scoped to the active Cadenza
profile, so a client authorized for one profile is not automatically authorized for
another.

Moving a recording to Trash keeps it locally until it is restored, deleted manually, or
removed by the configured retention period. Permanent deletion removes the associated
recording data and Cadenza-owned audio files from the active library. An automatic recovery
backup created before that deletion can retain an older copy until it is removed by the
three-backup rotation or automatic backups are explicitly cleared. A complete clear includes
both the active profile's backups, controlled incomplete staging artifacts, and any legacy
`Cadenza-Backups` artifacts. If a filesystem error prevents one artifact from being removed,
the clear operation reports the partial result and remaining managed artifacts. Unmerged
audio segments associated with a durable recording row are deliberately preserved after a
merge or persistence failure so that crash recovery remains possible. A process exit during
the capture-start interval before that row is committed can leave an unowned segments
directory that the current recovery scan does not adopt automatically.

## Permissions

| Permission | Why Cadenza uses it | When requested |
| --- | --- | --- |
| System Audio Recording | Capture audio produced by meeting applications | When the user enables it in Settings or starts a manual recording; automatic recording requires prior setup |
| Microphone | Add the user's voice to the recording | From a user-initiated recording or settings action; optional |
| Calendar | Read event timing and meeting metadata | When the user explicitly connects a calendar |
| Screen Recording | Read meeting-window information used by local meeting detection | Never requested automatically; background checks use read-only preflight gates |

macOS controls these permissions in **System Settings → Privacy & Security**. Revoking a
permission disables the related signal or capture source rather than authorizing a
different data path.

## On-device processing

- WhisperKit and Apple Speech can transcribe recordings on the Mac.
- SpeakerKit performs speaker diarization and voice-embedding work on the Mac.
- Apple Foundation Models can generate summaries on supported Macs.

Using this combination supports an offline transcription-and-summary workflow after any
required local model download has completed, but on-device summary generation requires a
Mac that Apple reports as eligible for Foundation Models. On other Macs, local transcription
still works while summaries require a configured cloud provider.

## Optional network and export boundaries

| Feature | Data that can leave the Mac | Trigger |
| --- | --- | --- |
| Cloud transcription (OpenAI or Gemini) | Recording audio and provider request metadata | User selects the provider and transcribes a recording |
| Cloud summaries and chat (OpenAI, Claude, Gemini, or MiniMax) | Transcript excerpts, summaries, selected meeting context, and prompts | User selects the provider and runs the feature |
| Cadenza web sync | Enabled recording metadata and text artifacts; audio only when its separate switch is enabled | User connects an account and enables sync |
| Notion or Craft | The recording content selected by the export integration | User connects the integration and exports manually or enables its automatic export |
| Markdown mirror and file exports | Selected recording content written to a user-chosen local folder | User configures or invokes the export |
| Google Calendar or Zoom metadata | OAuth requests and the calendar or meeting metadata needed by the integration | User explicitly connects the service |

Provider services have their own retention, training, and privacy terms. Review those terms
before sending confidential meeting material. Disconnecting a provider stops future use
but does not itself delete data already held by that provider.

AI transcription, summaries, action items, and chat responses can be incomplete or wrong.
Review important output against the recording before making legal, employment, medical,
financial, or operational decisions. Cloud providers, model downloads, subscriptions, and
hosted storage may also create charges under the provider or deployment operator's terms;
Cadenza does not pay or control those charges.

New Cadenza account sign-ins use `https://cadenzapp.com/api/v1` by default. Developers can
configure a different backend for new logins, while an existing profile remains bound to the
issuer it originally used. A self-hosted or official operator must publish its own privacy,
retention, account-deletion, security, and pricing terms.

When Web Sync is enabled, permanent local deletion creates a minimal durable tombstone and
the client retries the remote DELETE operation. If the Mac is offline or the service rejects
the request, the remote copy can remain until a later retry succeeds. Cadenza currently has
no client-side whole-account deletion flow. Server-side text retention and post-subscription
audio retention are deployment policy; the contract permits either read-only retention or
expiry of audio after grace, while synced text is not automatically removed by subscription
expiry. Consult the deployment operator before treating local deletion or sign-out as remote
erasure.

## Local MCP server

The MCP server is disabled by default and binds only to the loopback interface. Clients
must present a bearer token. Read access, write access, and meeting-context access are
separate scopes. Treat client configuration files containing a bearer token as sensitive,
and revoke a client from Cadenza settings when it is no longer trusted.

A second, read-only MCP endpoint lives on Cadenza Web (`POST /mcp`). It is opt-in
and token-gated. It can only read synced `ready` recordings that are still stored
in the cloud. Turning Web Sync off, signing out, or deleting a local recording
does not wipe that cloud history. Revoke the Web token from Settings → Integrations
when a remote agent should lose access.

## Test and screenshot isolation

`CADENZA_DATA_ROOT` is a DEBUG-only seam for Cadenza-owned files: profile metadata,
SwiftData stores, backups, chat history, and app-managed audio. It does not move
`UserDefaults`, Keychain records, macOS TCC grants, EventKit calendars, provider-side data,
or network traffic. `CADENZA_DATA_ROOT` and `CFFIXED_USER_HOME` must be pre-created under a
canonical system temporary root, owned by the current uid, private from group/world writes,
and the fixed home must be inside the data root. This keeps Foundation preferences and
caches from reusing the interactive user's state.

Fictional screenshot data is opt-in. `DemoSeedTests` requires
`TEST_RUNNER_CADENZA_DEMO_SEED_STORE` and accepts only a new, absolute store path below a
canonical system temporary directory. It resolves symlinks, rejects existing stores,
orphaned `-wal`, `-shm`, and `-journal` sidecars, repository paths, and the real Application
Support and Documents Cadenza trees before any SwiftData container is created. It also
requires an already-created, current-uid-owned ancestor below the temporary root that is
not group/world-writable; it will not create a fixture tree directly under shared
`/private/tmp`. The seed test receives only this opt-in store path; `CADENZA_DATA_ROOT` and
`CFFIXED_USER_HOME` are reserved for the later app launch and must not redirect the build
or test tooling.

The valid two-variable DEBUG launch selects `isolatedFixture` automatically; it takes no
extra launch arguments. That runtime opens the fixture store and chat path directly, uses
ephemeral defaults and authority plus a process-memory Keychain, and loads only fixture chat,
recordings, folders, and Trash. It does not call the real Keychain, TCC, EventKit, Google or
Zoom calendars, Web Sync, Notion/Craft external exports, MCP, meeting detection, global
hotkeys, recording hardware, maintenance, import post-processing, or automatic AI
generation. Local file and portable-archive exports remain local. The macOS grants
themselves are not relocated, so keep them ungranted and block network access for the DEBUG
binary as an independent defense. Verify the two isolation log lines and the exact process's
open files by Unix PID before interacting; terminate only that PID if any real account,
calendar, integration, or library appears.

Visual QA requires an unlocked Mac and confirms only the rendered fixture UI. It does not
exercise real permission or Keychain behavior and does not validate distribution signing,
Gatekeeper, or notarization.

## Recording notice

Cadenza cannot determine whether every participant has consented or whether recording is
lawful in a particular location or workplace. Before recording, tell participants and
follow applicable law, contracts, and organizational policy.
