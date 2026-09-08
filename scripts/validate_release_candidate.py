#!/usr/bin/env python3
"""Validate a staged macOS Release candidate without launching or installing it."""
import argparse
import json
import plistlib
from pathlib import Path
import subprocess


def validate_layout_and_settings(app: Path, settings: list) -> None:
    main = next(item['buildSettings'] for item in settings if item.get('target') == 'Cadenza')
    if main.get('CONFIGURATION') != 'Release':
        raise ValueError('Candidate build configuration must be Release')
    if main.get('SWIFT_OPTIMIZATION_LEVEL') not in ('-O', '-Osize'):
        raise ValueError('Candidate must use optimized Swift compilation')
    macos = app / 'Contents' / 'MacOS'
    debug_libraries = list(macos.glob('*.debug.dylib')) + list(macos.glob('__preview.dylib'))
    if debug_libraries:
        raise ValueError('Debug/preview dylibs are forbidden in a Release candidate')
    with (app / 'Contents' / 'Info.plist').open('rb') as stream:
        info = plistlib.load(stream)
    executable = info.get('CFBundleExecutable')
    if not executable or Path(executable).name != executable or not (macos / executable).is_file():
        raise ValueError('Missing standalone application executable')
    if info.get('CFBundleIdentifier') != main.get('PRODUCT_BUNDLE_IDENTIFIER'):
        raise ValueError('Candidate bundle identifier does not match build settings')


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    parser.add_argument('build_settings', type=Path)
    parser.add_argument('--expected-team', required=True)
    args = parser.parse_args()
    validate_layout_and_settings(args.app, json.loads(args.build_settings.read_text()))
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(args.app)], check=True)
    signature = subprocess.run(['codesign', '-dv', '--verbose=4', str(args.app)],
                               check=True, capture_output=True, text=True).stderr
    if f'TeamIdentifier={args.expected_team}' not in signature.splitlines():
        raise ValueError('Candidate signing team does not match the expected stable identity')
    print('Release configuration, optimization, bundle layout and signature verified')


if __name__ == '__main__':
    main()
