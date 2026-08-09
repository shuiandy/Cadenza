import contextlib
import importlib.util
import io
from pathlib import Path
import subprocess
import tempfile
import unittest


MODULE_PATH = Path(__file__).resolve().parents[1] / "check_repository_hygiene.py"
SPEC = importlib.util.spec_from_file_location("check_repository_hygiene", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class CandidateFileTests(unittest.TestCase):
    def run_check(self, repository: Path) -> tuple[int, str]:
        original_root = MODULE.REPO_ROOT
        MODULE.REPO_ROOT = repository
        try:
            with contextlib.redirect_stdout(io.StringIO()) as output:
                result = MODULE.main()
        finally:
            MODULE.REPO_ROOT = original_root

        return result, output.getvalue()

    def initialize_repository(self, repository: Path) -> None:
        subprocess.run(["git", "init", "-q"], cwd=repository, check=True)

    def test_staged_secret_is_scanned_instead_of_safe_worktree_version(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            repository = Path(temporary_directory)
            self.initialize_repository(repository)
            candidate = repository / "candidate.swift"
            secret = "sk-" + ("A" * 24)
            candidate.write_text(f'let token = "{secret}"\n', encoding="utf-8")
            subprocess.run(["git", "add", "candidate.swift"], cwd=repository, check=True)
            candidate.write_text("let token = nil\n", encoding="utf-8")

            result, output = self.run_check(repository)

            self.assertEqual(result, 1)
            self.assertIn("OpenAI API key", output)
            self.assertIn("candidate.swift", output)
            self.assertNotIn(secret, output)

    def test_safe_staged_blob_is_not_replaced_by_dirty_worktree_secret(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            repository = Path(temporary_directory)
            self.initialize_repository(repository)
            candidate = repository / "candidate.swift"
            candidate.write_text("let token = nil\n", encoding="utf-8")
            subprocess.run(["git", "add", "candidate.swift"], cwd=repository, check=True)
            candidate.write_text(
                f'let token = "sk-{("B" * 24)}"\n',
                encoding="utf-8",
            )

            result, _ = self.run_check(repository)

            self.assertEqual(result, 0)

    def test_deleted_worktree_file_does_not_hide_index_secret(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            repository = Path(temporary_directory)
            self.initialize_repository(repository)
            candidate = repository / "candidate.swift"
            candidate.write_text(
                f'let token = "sk-{("C" * 24)}"\n',
                encoding="utf-8",
            )
            subprocess.run(["git", "add", "candidate.swift"], cwd=repository, check=True)
            candidate.unlink()

            result, output = self.run_check(repository)

            self.assertEqual(result, 1)
            self.assertIn("OpenAI API key", output)
            self.assertIn("candidate.swift", output)

    def test_untracked_nonignored_candidate_is_scanned(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            repository = Path(temporary_directory)
            self.initialize_repository(repository)
            (repository / "tracked.txt").write_text("safe\n", encoding="utf-8")
            subprocess.run(["git", "add", "tracked.txt"], cwd=repository, check=True)
            forbidden_path = "/" + "Users/Example/Library/Application Support/Cadenza"
            (repository / "candidate.swift").write_text(
                f'let path = "{forbidden_path}"\n',
                encoding="utf-8",
            )

            result, output = self.run_check(repository)

            self.assertEqual(result, 1)
            self.assertIn("candidate.swift", output)

    def test_user_data_and_build_binary_extensions_are_rejected(self) -> None:
        forbidden_paths = (
            "recording.m4a",
            "meeting.mov",
            "recordings.sqlite-wal",
            "export.tar.gz",
            "coverage.profraw",
            "Tests.xcresult/Info.plist",
        )
        for relative_path in forbidden_paths:
            with self.subTest(relative_path=relative_path):
                with tempfile.TemporaryDirectory() as temporary_directory:
                    repository = Path(temporary_directory)
                    self.initialize_repository(repository)
                    candidate = repository / relative_path
                    candidate.parent.mkdir(parents=True, exist_ok=True)
                    candidate.write_bytes(b"\x00private binary data\xff")

                    result, output = self.run_check(repository)

                    self.assertEqual(result, 1)
                    self.assertIn(relative_path, output)
                    self.assertIn("user-data/build binary artifact", output)

    def test_reviewed_asset_and_license_types_are_allowed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            repository = Path(temporary_directory)
            self.initialize_repository(repository)
            asset_paths = (
                "Cadenza/Resources/Assets.xcassets/Icon.imageset/icon.png",
                "docs/screenshots/readme.png",
                "docs/design/previews/AppIcon-variant-monolith.svg.png",
            )
            for relative_path in asset_paths:
                asset = repository / relative_path
                asset.parent.mkdir(parents=True, exist_ok=True)
                asset.write_bytes(b"\x89PNG\r\n\x1a\n\x00\xff")
            license_file = repository / "ThirdPartyLicenses/Example-LICENSE.txt"
            license_file.parent.mkdir(parents=True)
            license_file.write_text("Example license text\n", encoding="utf-8")

            result, _ = self.run_check(repository)

            self.assertEqual(result, 0)

    def test_binary_image_outside_reviewed_asset_paths_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            repository = Path(temporary_directory)
            self.initialize_repository(repository)
            (repository / "recording-preview.png").write_bytes(
                b"\x89PNG\r\n\x1a\n\x00\xff",
            )

            result, output = self.run_check(repository)

            self.assertEqual(result, 1)
            self.assertIn("unreviewed binary artifact", output)
            self.assertIn("recording-preview.png", output)

    def test_ignored_local_file_is_not_scanned(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            repository = Path(temporary_directory)
            self.initialize_repository(repository)
            (repository / ".gitignore").write_text(".env.*\n", encoding="utf-8")
            ignored_path = "/" + "Users/Example/private"
            (repository / ".env.local").write_text(
                f'EXAMPLE_PATH="{ignored_path}"\n',
                encoding="utf-8",
            )

            result, _ = self.run_check(repository)

            self.assertEqual(result, 0)


if __name__ == "__main__":
    unittest.main()
