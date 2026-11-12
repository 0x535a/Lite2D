#!/usr/bin/env python3
"""Extract real App Intents metadata for the CMake-built native app; no app execution."""
import argparse
import json
from pathlib import Path
import subprocess


def capture(*args):
    return subprocess.check_output(args, text=True).strip()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--build', type=Path, required=True)
    parser.add_argument('--resources', type=Path, required=True)
    parser.add_argument('--deployment-target', default='14.0')
    args = parser.parse_args()
    args.build.mkdir(parents=True, exist_ok=True)
    args.resources.mkdir(parents=True, exist_ok=True)
    swift = Path(capture('xcrun', '--find', 'swiftc'))
    toolchain = swift.parents[2]
    sdk = capture('xcrun', '--show-sdk-path')
    version = capture('xcodebuild', '-version').split('Build version ')[-1].strip()
    spec = toolchain / 'usr/share/swift/SwiftConstantValues/AppIntents.json'
    protocols = json.loads(spec.read_text())
    protocols = protocols.get('constValueProtocols', []) if isinstance(protocols, dict) else protocols
    if not protocols:
        raise RuntimeError('No App Intents constant extraction protocols in this toolchain')
    protocol_file = args.build / 'protocols.json'
    protocol_file.write_text(json.dumps(protocols))
    constants = (args.build / 'Intents.swiftconstvalues').resolve()
    sources = args.build / 'sources.txt'
    sources.write_text(str(args.source.resolve()) + '\n')
    constant_list = args.build / 'const-list.txt'
    constant_list.write_text(str(constants) + '\n')
    target = f'arm64-apple-macosx{args.deployment_target}'
    subprocess.run([str(swift), '-frontend', '-c', '-primary-file', str(args.source), '-target', target,
                    '-parse-as-library', '-module-name', 'Lite2D', '-swift-version', '5', '-sdk', sdk,
                    '-const-gather-protocols-file', str(protocol_file), '-emit-const-values-path', str(constants),
                    '-o', str(args.build / 'Intents.o')], check=True)
    if not json.loads(constants.read_text()):
        raise RuntimeError('No App Intents constants extracted; refusing a metadata-less bundle')
    subprocess.run(['xcrun', 'appintentsmetadataprocessor', '--output', str(args.resources), '--toolchain-dir', str(toolchain),
                    '--module-name', 'Lite2D', '--sdk-root', sdk, '--xcode-version', version,
                    '--platform-family', 'macOS', '--deployment-target', args.deployment_target,
                    '--target-triple', target, '--source-file-list', str(sources), '--swift-const-vals-list', str(constant_list)], check=True)
    metadata = args.resources / 'Metadata.appintents/extract.actionsdata'
    if not metadata.is_file() or metadata.stat().st_size == 0:
        raise RuntimeError('App Intents action metadata was not exported')


if __name__ == '__main__':
    main()
