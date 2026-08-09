#!/usr/bin/env python3
"""Validate locale and printf-placeholder coverage for the full string catalog."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path


REQUIRED_LOCALES = ("de", "es", "fr", "ja", "ko", "zh-Hans")
REQUIRED_KEYS = (
    "The saved transcription provider “%@” is invalid. Choose a provider in Settings → Transcription.",
    "%@ cannot be used for post-recording transcription. Choose a transcription provider in Settings.",
    "%@ cannot be used for realtime transcription. Choose Apple, OpenAI, or Gemini in Settings.",
    "%@ does not support the selected language (%@). Cadenza will not switch providers automatically.",
    "The local Whisper model “%@” is unavailable. Download it in Settings → Transcription.",
    "Add an API key for %@ in Settings. Cadenza will not use another transcription provider automatically.",
    "Transcribe meeting/system audio during recording with the provider you select.",
    "Apple live transcription is processed on this Mac. No API key is required.",
    "Live transcription uses the meeting/system audio track only. Microphone audio is not sent to realtime providers.",
    "Meeting/system audio is sent to %@ for live transcription. Microphone audio is not sent.",
    "Live transcription unavailable: %@ Recording continues normally.",
    "Live transcription unavailable: connection timed out. Recording continues normally.",
    "Live transcription disconnected. Recording continues normally.",
    "Live transcription is already active.",
    "Live transcription unavailable. Check the selected provider settings or network connection. Recording continues normally.",
    "Recording Error",
    "OK",
    "The operation timed out.",
)
PRINTF_PATTERN = re.compile(
    r"%(?:(\d+)\$)?[-+0 #'I]*(?:\d+)?(?:\.(?:\d+))?"
    r"(hh|h|ll|l|L|z|j|t)?([@a-zA-Z])"
)


class PlaceholderFormatError(ValueError):
    pass


def placeholder_signature(value: str) -> tuple[tuple[int, str], ...]:
    placeholders: list[tuple[int, str]] = []
    implicit_position = 1
    saw_explicit = False
    saw_implicit = False
    index = 0

    while index < len(value):
        if value[index] != "%":
            index += 1
            continue
        if index + 1 < len(value) and value[index + 1] == "%":
            index += 2
            continue

        match = PRINTF_PATTERN.match(value, index)
        if match is None:
            raise PlaceholderFormatError(f"malformed printf token at offset {index}: {value!r}")

        explicit_position, length, conversion = match.groups()
        if explicit_position is None:
            saw_implicit = True
            position = implicit_position
            implicit_position += 1
        else:
            saw_explicit = True
            position = int(explicit_position)
            if position < 1:
                raise PlaceholderFormatError(f"invalid printf position {position}: {value!r}")

        if saw_explicit and saw_implicit:
            raise PlaceholderFormatError(f"mixed positional and implicit printf tokens: {value!r}")

        placeholders.append((position, f"{length or ''}{conversion}"))
        index = match.end()

    return tuple(sorted(placeholders))


def localized_value(entry: dict, locale: str) -> str | None:
    return (
        entry.get("localizations", {})
        .get(locale, {})
        .get("stringUnit", {})
        .get("value")
    )


def main() -> int:
    catalog_path = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("Cadenza/Resources/Localizable.xcstrings")
    catalog = json.loads(catalog_path.read_text(encoding="utf-8"))
    strings = catalog.get("strings", {})
    errors: list[str] = []

    if catalog.get("sourceLanguage") != "en":
        errors.append("sourceLanguage must be en")

    for key in REQUIRED_KEYS:
        if key not in strings:
            errors.append(f"missing required key: {key}")

    validated_keys = 0
    for key, entry in strings.items():
        # Xcode may retain one empty extraction artifact. It is not a visible
        # resource and has no meaningful translation contract.
        if not key:
            continue
        if not isinstance(entry, dict):
            errors.append(f"invalid catalog entry for {key}")
            continue
        validated_keys += 1

        source = localized_value(entry, "en") or key
        try:
            source_signature = placeholder_signature(source)
        except PlaceholderFormatError as error:
            errors.append(f"en: {error}")
            continue
        for locale in REQUIRED_LOCALES:
            value = localized_value(entry, locale)
            if not value:
                errors.append(f"{locale}: missing translation for {key}")
                continue
            try:
                signature = placeholder_signature(value)
            except PlaceholderFormatError as error:
                errors.append(f"{locale}: {error}")
                continue
            if signature != source_signature:
                errors.append(
                    f"{locale}: placeholder mismatch for {key}: "
                    f"expected {source_signature}, got {signature}"
                )

    if errors:
        for error in errors:
            print(error, file=sys.stderr)
        return 1

    print(
        f"validated {validated_keys} catalog strings across "
        f"{len(REQUIRED_LOCALES)} locales"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
