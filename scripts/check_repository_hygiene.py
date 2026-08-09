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


def main() -> int:
    failures: list[str] = []

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

    if failures:
        print("Repository hygiene check failed:")
        for failure in failures:
            print(f"- {failure}")
        return 1

    print("Repository hygiene check passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
