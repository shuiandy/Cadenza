import importlib.util
from pathlib import Path
import plistlib
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('release_check', Path(__file__).parents[1] / 'validate_release_candidate.py')
release_check = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release_check)


class ReleaseCandidateTests(unittest.TestCase):
    def test_release_layout_and_rejection_of_signed_debug_shape(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / 'Cadenza.app'
            macos = app / 'Contents' / 'MacOS'
            macos.mkdir(parents=True)
            (macos / 'Cadenza').write_bytes(b'fictional executable')
            (app / 'Contents' / 'Info.plist').write_bytes(plistlib.dumps({
                'CFBundleExecutable': 'Cadenza', 'CFBundleIdentifier': 'test.cadenza'}))
            settings = [{'target': 'Cadenza', 'buildSettings': {
                'CONFIGURATION': 'Release', 'SWIFT_OPTIMIZATION_LEVEL': '-O',
                'PRODUCT_BUNDLE_IDENTIFIER': 'test.cadenza'}}]
            release_check.validate_layout_and_settings(app, settings)
            for name in ['Cadenza.debug.dylib', '__preview.dylib']:
                library = macos / name
                library.touch()
                with self.assertRaises(ValueError):
                    release_check.validate_layout_and_settings(app, settings)
                library.unlink()
            for key, value in [('CONFIGURATION', 'Debug'), ('SWIFT_OPTIMIZATION_LEVEL', '-Onone')]:
                original = settings[0]['buildSettings'][key]
                settings[0]['buildSettings'][key] = value
                with self.assertRaises(ValueError):
                    release_check.validate_layout_and_settings(app, settings)
                settings[0]['buildSettings'][key] = original
