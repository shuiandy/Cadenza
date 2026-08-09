# Beta acceptance plan

Code review and automated tests cannot establish whether people understand or trust a
meeting recorder. Run this protocol against a signed release candidate before describing
Cadenza as ready for general users.

## Participants and devices

- Recruit 5–8 participants, including at least 3 people who do not develop software.
- Include both privacy-sensitive professional users and people who mainly want convenient
  meeting notes.
- Cover Apple silicon and Intel if both remain supported, plus the smallest and largest
  practical display configurations on macOS 26.
- Use a staged call with fictional content. Do not collect a participant's real work
  meeting, calendar, or transcript for the test.

## Core tasks

Give participants the outcome, not step-by-step instructions:

1. Install and open Cadenza, then explain in their own words what it will store locally and
   what could be sent to a cloud provider.
2. Make a two-minute manual recording, intentionally denying one optional permission, and
   recover without developer help.
3. Pause, resume, and stop. At each point, ask whether recording is active and which audio
   sources are included.
4. Find the completed recording, read its transcript and summary, and recover from one
   simulated provider failure.
5. Export a copy, move the recording to Trash, restore it, and identify how to delete it
   permanently.
6. Review automatic recording settings and the participant-notice warning. Enable the
   feature only if the participant can explain when it starts and what prior setup it needs.

## Measures

Record help requests, wrong turns, task completion time, and short verbatim feedback that
does not contain meeting content. Use these release gates:

- At least 80% complete the first manual recording and find its result without help.
- Every participant correctly identifies the recording state after pause, resume, and stop.
- Every participant can identify whether processing is local or uses a selected provider.
- Permission denial is recoverable without reinstalling or using Terminal.
- Median trust/confidence score is at least 4 out of 5 after the data-flow explanation.
- No participant believes automatic recording is enabled by default.

Any data loss, undisclosed upload, false recording-state indication, unrecoverable permission
path, or participant-consent ambiguity is a release blocker regardless of the aggregate
scores.

## Visual checks during the session

Repeat the recording overlay tasks with the largest supported Cadenza UI scale and macOS
accessibility text size. Verify that titles may truncate but microphone, pause/resume, and
stop controls remain visible, reachable, and inside the active display. Check English and
Simplified Chinese at minimum; sample the other supported locales with their longest labels.

Automated fixture screenshots and layout checks require an unlocked Mac. Run them only with
the documented DEBUG isolation recipe: a new system-temporary `CADENZA_DATA_ROOT`,
`CFFIXED_USER_HOME` inside that root, a store seeded through
`TEST_RUNNER_CADENZA_DEMO_SEED_STORE`, blocked network access, open-file verification, and
PID-specific termination. A valid two-variable launch selects the built-in `isolatedFixture`
policy with no extra arguments; it uses ephemeral defaults/auth and a process-memory Keychain
and does not call live permission, calendar, capture, AI, MCP, Web Sync, or Notion/Craft
external paths. Local file and portable-archive exports remain local. These checks validate
fixture rendering only. They do not count as evidence for real TCC permission recovery, real
Keychain behavior, signed upgrades, Gatekeeper, or notarization.

## Performance and scale checks

Use the isolated fixture runtime for local-library scale and rendering measurements only.
It intentionally disables hardware capture, permission and calendar access, automatic
generation, MCP, and Web Sync, so it cannot produce evidence for those paths. Run capture
and network measurements separately on a signed release candidate with a staged fictional
call and a dedicated sanitized integration account; never point either workflow at a real
library. Record the device, build hash, library size, wall-clock time, peak resident memory,
and longest main-thread stall. These are release measurements, not values to infer from unit
tests.

- Seed at least 5,000 recordings, including long transcripts and summaries. Verify launch,
  list scrolling, search, Trash, and detail navigation remain responsive, with no main-thread
  stall over 100 ms in the network-blocked fixture runtime.
- In the separate Web Sync integration environment, run two unchanged passes against an
  already-synchronized fictional library. The second pass must fetch lightweight candidate
  metadata only, perform no transcript payload builds or network writes, and inspect at most
  eight synchronized audio files.
- Stop a two-hour segmented recording, then immediately try to start another. Saving must be
  visibly communicated, controls must not claim the app is ready, the UI must remain
  responsive, and every recovery segment must survive any injected merge failure.
- Repeat the recording finalization measurement on the oldest supported Intel Mac and on a
  current Apple silicon Mac. Record the stop-to-saved duration and peak memory; any crash,
  beachball lasting more than two seconds, or missing recovery artifact blocks release.
- Exercise sleep/wake, network loss, entitlement refusal/reopen, and an interrupted durable
  audio upload. The next pass must resume or cool down without a 60-second full-library work
  loop.

## Report

For each participant, record only a participant number, device/OS category, completed tasks,
help count, permission recovery result, trust score, and sanitized observations. Summarize
P0/P1 findings separately from preferences. Do not attach recordings, transcripts, calendar
events, API keys, or unredacted logs to an issue.
