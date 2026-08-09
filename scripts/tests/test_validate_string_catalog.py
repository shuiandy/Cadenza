import importlib.util
from pathlib import Path
import unittest


MODULE_PATH = Path(__file__).resolve().parents[1] / "validate_string_catalog.py"
SPEC = importlib.util.spec_from_file_location("validate_string_catalog", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class PlaceholderSignatureTests(unittest.TestCase):
    def test_positional_translation_matches_implicit_source(self) -> None:
        self.assertEqual(
            MODULE.placeholder_signature("%@ and %@"),
            MODULE.placeholder_signature("%2$@ und %1$@"),
        )

    def test_duplicate_position_does_not_match_two_source_arguments(self) -> None:
        self.assertNotEqual(
            MODULE.placeholder_signature("%@ and %@"),
            MODULE.placeholder_signature("%1$@ und %1$@"),
        )

    def test_escaped_percent_is_not_a_placeholder(self) -> None:
        self.assertEqual(MODULE.placeholder_signature("progress: %%"), ())
        self.assertEqual(MODULE.placeholder_signature("%%@"), ())
        self.assertNotEqual(
            MODULE.placeholder_signature("%@"),
            MODULE.placeholder_signature("%%@"),
        )

    def test_conversion_length_is_part_of_signature(self) -> None:
        self.assertNotEqual(
            MODULE.placeholder_signature("%d"),
            MODULE.placeholder_signature("%lld"),
        )

    def test_mixed_or_malformed_tokens_are_rejected(self) -> None:
        with self.assertRaises(MODULE.PlaceholderFormatError):
            MODULE.placeholder_signature("%1$@ %@")
        with self.assertRaises(MODULE.PlaceholderFormatError):
            MODULE.placeholder_signature("dangling %")


if __name__ == "__main__":
    unittest.main()
