#!/usr/bin/env python3
"""Reject unsafe indexed or non-ignored untracked repository artifacts."""

from __future__ import annotations

import os
import re
import subprocess
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parent.parent

FORBIDDEN_FILES = {
    "AGENTS.md",
    "CLAUDE.md",
    "CODEX.md",
    "MEMORY.md",
    "PLAN.md",
    "RTK.md",
    "task_plan.md",
    "findings.md",
    "progress.md",
}

FORBIDDEN_PREFIXES = (
    ".claude/",
    ".agents/",
    ".codex/",
    ".planning/",
    ".superpowers/",
    ".github/workflows/claude",
    "docs/plans/",
    "docs/superpowers/",
)

FORBIDDEN_BINARY_SUFFIXES = frozenset(
    {
        # Audio and video can contain real recording data.
        ".3g2",
        ".3gp",
        ".aac",
        ".aif",
        ".aiff",
        ".alac",
        ".amr",
        ".avi",
        ".caf",
        ".flac",
        ".m4a",
        ".m4b",
        ".m4v",
        ".mkv",
        ".mov",
        ".mp3",
        ".mp4",
        ".mpeg",
        ".mpg",
        ".ogg",
        ".opus",
        ".wav",
        ".webm",
        ".wma",
        ".wmv",
        # Local databases and their sidecars can contain user data.
        ".db",
        ".db-journal",
        ".db-shm",
        ".db-wal",
        ".db3",
        ".sqlite",
        ".sqlite-journal",
        ".sqlite-shm",
        ".sqlite-wal",
        ".sqlite3",
        ".sqlite3-journal",
        ".sqlite3-shm",
        ".sqlite3-wal",
        ".store",
        ".store-journal",
        ".store-shm",
        ".store-wal",
        # Archives can conceal user data or generated output.
        ".7z",
        ".bz2",
        ".gz",
        ".rar",
        ".tar",
        ".tgz",
        ".txz",
        ".xz",
        ".zip",
        ".zst",
        # Coverage output is generated locally.
        ".profraw",
    }
)

REVIEWED_BINARY_ASSET_SUFFIXES = frozenset(
    {
        ".gif",
        ".heic",
        ".icns",
        ".jpeg",
        ".jpg",
        ".pdf",
        ".png",
        ".tif",
        ".tiff",
        ".webp",
    }
)

REVIEWED_BINARY_ASSET_PREFIXES = (
    "Cadenza/Resources/Assets.xcassets/",
    "docs/screenshots/",
)

REVIEWED_BINARY_ASSET_FILES = frozenset(
    {
        "docs/design/previews/AppIcon-variant-monolith.svg.png",
        "docs/design/previews/AppIcon-variant-orbit.svg.png",
        "docs/design/previews/AppIcon-variant-plate.svg.png",
    }
)

FORBIDDEN_CONTENT = (
    (re.compile(r"/Users/[A-Za-z0-9._-]+/"), "absolute macOS user path"),
    (re.compile(r"\bDEVELOPMENT_TEAM\s*[=:]"), "hard-coded Apple development team"),
    (
        re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"),
        "private key material",
    ),
    (re.compile(r"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b"), "AWS access key"),
    (
        re.compile(
            r"\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{30,}\b"
            r"|\bgithub_pat_[A-Za-z0-9_]{20,}\b"
        ),
        "GitHub access token",
    ),
    (re.compile(r"\bAIza[0-9A-Za-z_-]{35}\b"), "Google API key"),
    (re.compile(r"\bxox[baprs]-[0-9A-Za-z-]{20,}\b"), "Slack token"),
    (re.compile(r"\bsk_live_[0-9A-Za-z]{16,}\b"), "Stripe live secret"),
    (re.compile(r"\bsk-(?:proj-)?[0-9A-Za-z_-]{20,}\b"), "OpenAI API key"),
)

# Source comments ship to the public mirror, so they stay in English. String
# literals are exempt: localization fixtures legitimately carry CJK text.
CJK_PATTERN = re.compile(
    "["
    "\u3000-\u303f"  # CJK punctuation
    "\u3400-\u4dbf"  # CJK unified ideographs extension A
    "\u4e00-\u9fff"  # CJK unified ideographs
    "\uf900-\ufaff"  # CJK compatibility ideographs
    "\uff01-\uff60"  # fullwidth forms
    "]"
)

COMMENT_SCANNED_SUFFIXES = frozenset({".swift"})

# Ratchet for the pre-existing Chinese comments. New files are gated
# immediately; these are translated in batches and each cleaned file must be
# deleted from this set. The check below fails on stale entries, so the list
# can only shrink.
LEGACY_COMMENT_FILES: frozenset[str] = frozenset(
    {
        "Cadenza/App/AppState.swift",
        "Cadenza/Models/AgentArtifact.swift",
        "Cadenza/Models/ArtifactTargetKey.swift",
        "Cadenza/Models/MeetingEvent.swift",
        "Cadenza/Models/NavigationDestination.swift",
        "Cadenza/Services/AI/AIGenerationGate.swift",
        "Cadenza/Services/AI/MeetingPrepContextBuilder.swift",
        "Cadenza/Services/AI/MeetingPrepEligibility.swift",
        "Cadenza/Services/AI/MeetingPrepFingerprint.swift",
        "Cadenza/Services/AI/MeetingPrepGenerator.swift",
        "Cadenza/Services/AI/MeetingPrepScheduleDecision.swift",
        "Cadenza/Services/AI/MeetingPrepScheduler.swift",
        "Cadenza/Services/AI/SummaryTranscriptFormatter.swift",
        "Cadenza/Services/Cadenza/CadenzaAuthService.swift",
        "Cadenza/Services/Calendar/GoogleEventParser.swift",
        "Cadenza/Services/Export/BatchFileExporter.swift",
        "Cadenza/Services/Export/ExportContentRenderer.swift",
        "Cadenza/Services/Export/PortableArchive/PortableArchiveExporter.swift",
        "Cadenza/Services/Export/PortableArchive/PortableArchiveSchema.swift",
        "Cadenza/Services/Export/PortableArchive/PortableArchiveWriter.swift",
        "Cadenza/Services/MCP/MCPToolRegistry.swift",
        "Cadenza/Services/Meeting/CalendarEventMapping.swift",
        "Cadenza/Services/Persistence/RecordingsStore+Archive.swift",
        "Cadenza/Services/Persistence/RecordingsStore+Artifacts.swift",
        "Cadenza/Services/Persistence/RecordingsStore.swift",
        "Cadenza/Services/PostProcessing/PostProcessingCoordinator.swift",
        "Cadenza/Services/Recording/RecordingEngine.swift",
        "Cadenza/Shared/DTOs/MeetingEventDTO.swift",
        "Cadenza/Utilities/CadenzaButtonStyle.swift",
        "Cadenza/Utilities/ColorHex.swift",
        "Cadenza/Utilities/PlatformCompatibility.swift",
        "Cadenza/Utilities/ScaledFont.swift",
        "Cadenza/Views/Calendar/EventDetailSheet.swift",
        "Cadenza/Views/Calendar/MeetingPrepSection.swift",
        "Cadenza/Views/Chat/FloatingAIChatButton.swift",
        "Cadenza/Views/Components/ExportSavePanel.swift",
        "Cadenza/Views/Components/Toast.swift",
        "Cadenza/Views/Main/MainWindow.swift",
        "Cadenza/Views/Main/RecordingOverlayPanel.swift",
        "Cadenza/Views/Recordings/RecordingDetailView.swift",
        "Cadenza/Views/Recordings/RecordingsContentView.swift",
        "Cadenza/Views/TabBar/TabContentView.swift",
        "CadenzaTests/AI/ChatHangReproTests.swift",
        "CadenzaTests/AI/MeetingPrepContextBuilderTests.swift",
        "CadenzaTests/AI/MeetingPrepGeneratorTests.swift",
        "CadenzaTests/AI/MeetingPrepSchedulerTests.swift",
        "CadenzaTests/AI/SummaryPromptTests.swift",
        "CadenzaTests/Calendar/CalendarEventMappingTests.swift",
        "CadenzaTests/Calendar/GoogleEventParserTests.swift",
        "CadenzaTests/Export/BatchFileExporterTests.swift",
        "CadenzaTests/Export/ExportContentRendererTests.swift",
        "CadenzaTests/Export/PortableArchiveRestorer.swift",
        "CadenzaTests/Export/PortableArchiveRoundTripTests.swift",
        "CadenzaTests/Export/PortableArchiveValidator.swift",
        "CadenzaTests/Export/PortableArchiveWriterTests.swift",
        "CadenzaTests/MCP/MCPMeetingPrepToolsTests.swift",
        "CadenzaTests/MCP/MCPToolsTests.swift",
        "CadenzaTests/Persistence/ArtifactStoreTests.swift",
        "CadenzaTests/Persistence/RecordingsStoreTagTests.swift",
        "CadenzaTests/Persistence/RecordingsStoreTests.swift",
        "CadenzaTests/Services/BulkExportCoordinatorTests.swift",
        "CadenzaTests/Services/CraftExportLedgerTests.swift",
        "CadenzaTests/Services/NotionExportedIDsTests.swift",
        "CadenzaTests/Services/TagNormalizerTests.swift",
        "CadenzaTests/UI/ButtonHitTestingTests.swift",
        "CadenzaTests/UI/ExportLocalizationTests.swift",
        "CadenzaTests/UI/NavigationReturnTests.swift",
        "CadenzaTests/UI/ViewLayerLocalizationTests.swift",
        "CadenzaTests/UI/WorkspacePanelSizingTests.swift",
    }
)


def git_file_list(*arguments: str) -> list[str]:
    result = subprocess.run(
        ["git", "ls-files", "-z", *arguments],
        cwd=REPO_ROOT,
        check=True,
        capture_output=True,
    )
    return [os.fsdecode(item) for item in result.stdout.split(b"\0") if item]


def candidate_files() -> list[tuple[str, str]]:
    indexed = ((relative_path, "index") for relative_path in git_file_list("--cached"))
    untracked = (
        (relative_path, "untracked")
        for relative_path in git_file_list("--others", "--exclude-standard")
    )
    return [*indexed, *untracked]


def read_candidate(relative_path: str, source: str) -> bytes:
    if source == "index":
        result = subprocess.run(
            ["git", "show", "--no-ext-diff", "--no-textconv", f":{relative_path}"],
            cwd=REPO_ROOT,
            check=True,
            capture_output=True,
        )
        return result.stdout

    absolute_path = REPO_ROOT / relative_path
    if absolute_path.is_symlink():
        return os.fsencode(os.readlink(absolute_path))
    return absolute_path.read_bytes()


def is_forbidden_binary_path(path: Path) -> bool:
    if path.suffix.lower() in FORBIDDEN_BINARY_SUFFIXES:
        return True
    return any(part.lower().endswith(".xcresult") for part in path.parts)


def is_reviewed_binary_asset(relative_path: str, path: Path) -> bool:
    if path.suffix.lower() not in REVIEWED_BINARY_ASSET_SUFFIXES:
        return False
    return relative_path in REVIEWED_BINARY_ASSET_FILES or relative_path.startswith(
        REVIEWED_BINARY_ASSET_PREFIXES,
    )


def decode_text(content: bytes) -> str | None:
    if b"\0" in content:
        return None
    try:
        return content.decode("utf-8")
    except UnicodeDecodeError:
        return None


def skip_swift_string(text: str, index: int, hash_count: int) -> int:
    """Return the index just past the Swift string literal starting at `index`."""
    length = len(text)
    closing_hashes = "#" * hash_count
    escapes = "\\" + closing_hashes

    if text.startswith('"""', index):
        terminator = '"""' + closing_hashes
        probe = index + 3
        while probe < length:
            if text.startswith(escapes, probe):
                probe += len(escapes) + 1
                continue
            if text.startswith(terminator, probe):
                return probe + len(terminator)
            probe += 1
        return length

    terminator = '"' + closing_hashes
    probe = index + 1
    while probe < length:
        if text.startswith(escapes, probe):
            probe += len(escapes) + 1
            continue
        if text[probe] == "\n":
            return probe
        if text.startswith(terminator, probe):
            return probe + len(terminator)
        probe += 1
    return length


def swift_comment_mask(text: str) -> list[bool]:
    """Mark every character that sits inside a Swift comment."""
    mask = [False] * len(text)
    length = len(text)
    index = 0
    block_depth = 0

    while index < length:
        if block_depth:
            if text.startswith("/*", index):
                block_depth += 1
                mask[index] = mask[index + 1] = True
                index += 2
                continue
            if text.startswith("*/", index):
                block_depth -= 1
                mask[index] = mask[index + 1] = True
                index += 2
                continue
            mask[index] = True
            index += 1
            continue

        if text.startswith("//", index):
            end = text.find("\n", index)
            end = length if end == -1 else end
            for position in range(index, end):
                mask[position] = True
            index = end
            continue

        if text.startswith("/*", index):
            block_depth = 1
            mask[index] = mask[index + 1] = True
            index += 2
            continue

        # Raw strings (#"..."#) disable backslash escaping, so the delimiter
        # length has to be carried into the scan.
        hash_count = 0
        probe = index
        while probe < length and text[probe] == "#":
            hash_count += 1
            probe += 1
        if hash_count and probe < length and text[probe] == '"':
            index = skip_swift_string(text, probe, hash_count)
            continue

        if text[index] == '"':
            index = skip_swift_string(text, index, 0)
            continue

        index += 1

    return mask


def chinese_comment_lines(text: str) -> list[int]:
    """Return 1-based line numbers whose comment portion contains CJK text."""
    mask = swift_comment_mask(text)
    findings: list[int] = []
    line_number = 1
    line_start = 0

    for index in range(len(text) + 1):
        if index != len(text) and text[index] != "\n":
            continue
        commented = "".join(
            text[position]
            for position in range(line_start, index)
            if mask[position]
        )
        if CJK_PATTERN.search(commented):
            findings.append(line_number)
        line_number += 1
        line_start = index + 1

    return findings


def main() -> int:
    failures: list[str] = []
    scanned_for_comments: set[str] = set()
    cleaned_legacy_files: set[str] = set()

    for relative_path, source in candidate_files():
        path = Path(relative_path)
        if path.name in FORBIDDEN_FILES or relative_path.startswith(FORBIDDEN_PREFIXES):
            failures.append(f"local/assistant artifact in {source}: {relative_path}")
            continue
        if (
            path.name.startswith(".env")
            and path.name != ".env.example"
        ) or path.suffix.lower() == ".pem":
            failures.append(f"secret artifact in {source}: {relative_path}")
            continue
        if is_forbidden_binary_path(path):
            failures.append(
                f"user-data/build binary artifact in {source}: {relative_path}",
            )
            continue

        try:
            content = read_candidate(relative_path, source)
        except (OSError, subprocess.CalledProcessError):
            failures.append(f"unable to inspect {source} content: {relative_path}")
            continue

        text = decode_text(content)
        if text is None:
            if not is_reviewed_binary_asset(relative_path, path):
                failures.append(f"unreviewed binary artifact in {source}: {relative_path}")
            continue

        for pattern, description in FORBIDDEN_CONTENT:
            if pattern.search(text):
                failures.append(f"{description} in {source}: {relative_path}")

        if path.suffix.lower() in COMMENT_SCANNED_SUFFIXES:
            scanned_for_comments.add(relative_path)
            comment_lines = chinese_comment_lines(text)
            if comment_lines and relative_path not in LEGACY_COMMENT_FILES:
                shown = ", ".join(str(line) for line in comment_lines[:5])
                if len(comment_lines) > 5:
                    shown += f", +{len(comment_lines) - 5} more"
                failures.append(
                    f"non-English source comment in {source}: "
                    f"{relative_path} (lines {shown})",
                )
            elif not comment_lines and relative_path in LEGACY_COMMENT_FILES:
                cleaned_legacy_files.add(relative_path)

    # Keep the ratchet honest: an exemption for a file that is already clean
    # (or no longer exists) has to go, otherwise the list silently rots.
    stale_exemptions = cleaned_legacy_files | (
        LEGACY_COMMENT_FILES - scanned_for_comments
    )
    for relative_path in sorted(stale_exemptions):
        failures.append(
            f"stale comment exemption: remove {relative_path} from "
            "LEGACY_COMMENT_FILES",
        )

    if failures:
        print("Repository hygiene check failed:")
        for failure in failures:
            print(f"- {failure}")
        return 1

    print("Repository hygiene check passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
