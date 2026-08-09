# Contributing to Cadenza

Thank you for helping improve Cadenza. Changes should preserve users' recordings,
privacy, and macOS permission choices before optimizing for convenience.

## Development setup

You need macOS 26 or later, Xcode 26 or later, and XcodeGen 2.46.0 (the version
enforced by CI). If Homebrew has moved to a newer release, review the generated
project diff before intentionally updating the CI version gate.

```bash
brew install xcodegen
xcodegen generate
xcodebuild build -project Cadenza.xcodeproj -scheme Cadenza \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
```

The no-sign build is intended for compilation and automated tests. To run recording
features, select your own Apple Development team in Xcode and use a stable, unique
bundle identifier so macOS permissions remain attached to the same signed app.

## Tests

Run the complete discovered suite before opening a pull request:

```bash
xcodebuild test -project Cadenza.xcodeproj -scheme Cadenza \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
```

After editing `project.yml`, regenerate `Cadenza.xcodeproj` and include the generated
project change. Validate the string catalog after any user-facing copy change:

```bash
python3 -m json.tool Cadenza/Resources/Localizable.xcstrings >/dev/null
python3 -m json.tool Cadenza/Resources/InfoPlist.xcstrings >/dev/null
python3 scripts/validate_string_catalog.py
python3 -m unittest discover -s scripts/tests
```

## Product and privacy invariants

- Never commit recordings, transcripts, credentials, `.env` files, or local assistant
  state. Tests and screenshots must use fictional data.
- Automatic/background paths must never trigger microphone or screen-recording permission
  prompts. Permission requests must remain user initiated.
- Preserve segmented audio after merge or persistence failures so crash recovery remains
  possible.
- Every user-visible source string must be English and have non-empty `zh-Hans`, `ja`,
  `ko`, `fr`, `de`, and `es` translations in the same string catalog change.
- Use Swift Testing (`import Testing`) and the repository's existing factories and mocks.
- Keep changes focused and do not rewrite unrelated code in an already dirty worktree.

## Pull requests

Please include:

- the user-visible outcome and motivation;
- the important implementation and privacy/security tradeoffs;
- exact test commands and results;
- screenshots made with fictional data for visual changes;
- localization updates for every affected entry point.

Report security vulnerabilities privately as described in [SECURITY.md](SECURITY.md).
