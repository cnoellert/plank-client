#!/usr/bin/env python3
"""Stage an isolated native Mac app with a verified dynamic-library closure."""
import argparse
import json
import plistlib
import re
import shutil
import subprocess
from pathlib import Path

def run(*args):
    return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT)

def dependencies(binary):
    return [line.strip().split(' (compatibility')[0]
            for line in run('otool', '-L', str(binary)).splitlines()[1:]]

def validate_target(binary):
    details = run('vtool', '-show-build', str(binary))
    match = re.search(r'minos\s+(\d+)\.(\d+)', details)
    if 'platform MACOS' not in details or not match or tuple(map(int, match.groups())) > (15, 0):
        raise RuntimeError(f'{binary.name} is not a macOS 15-compatible build')
    if run('lipo', '-archs', str(binary)).strip() != 'arm64':
        raise RuntimeError(f'{binary.name} is not the expected Apple silicon build')

parser = argparse.ArgumentParser()
parser.add_argument('--app', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--ffmpeg-prefix', type=Path, required=True)
parser.add_argument('--ffmpeg-source', type=Path, required=True)
parser.add_argument('--opus-license', type=Path, required=True)
parser.add_argument('--sodium-license', type=Path, required=True)
parser.add_argument('--identity', required=True)
args = parser.parse_args()
if args.output.exists():
    raise RuntimeError('Output already exists; choose a fresh staging directory')
shutil.copytree(args.app, args.output, symlinks=True)
contents = args.output / 'Contents'
info_path = contents / 'Info.plist'
info = plistlib.loads(info_path.read_bytes())
root = Path(__file__).resolve().parent.parent
info['PLANKSourceCommit'] = run('git', '-C', str(root), 'rev-parse', 'HEAD').strip()
info_path.write_bytes(plistlib.dumps(info))
executable = contents / 'MacOS' / info['CFBundleExecutable']
frameworks = contents / 'Frameworks'
frameworks.mkdir(exist_ok=True)
work = [executable]
seen = set()
closure = {}
while work:
    binary = work.pop()
    if binary in seen:
        continue
    seen.add(binary)
    validate_target(binary)
    for original in dependencies(binary):
        if original.startswith('/System/Library/') or original.startswith('/usr/lib/'):
            continue
        # dylib IDs appear in otool -L too. Avoid treating the current image
        # as a separate dependency and reject any unexpected external closure.
        if binary != executable and Path(original).name == binary.name:
            continue
        source = args.ffmpeg_prefix / 'lib' / Path(original).name
        if not source.is_file() or not source.name.startswith(('libavcodec.', 'libavutil.', 'libswscale.', 'libswresample.')):
            raise RuntimeError(f'Unexpected non-system dependency: {Path(original).name}')
        source = source.resolve()
        destination = frameworks / source.name
        if not destination.exists():
            shutil.copy2(source, destination)
            destination.chmod(0o755)
            run('install_name_tool', '-id', '@rpath/' + destination.name, str(destination))
            work.append(destination)
        run('install_name_tool', '-change', original, '@rpath/' + destination.name, str(binary))
        closure[source.name] = destination
# Remove build-machine rpaths and use a relative in-bundle Frameworks path.
loads = run('otool', '-l', str(executable))
paths = re.findall(r'cmd LC_RPATH\n\s*cmdsize \d+\n\s*path ([^\n]+?) \(offset', loads)
for path in paths:
    if path.startswith('/') and not path.startswith('/usr/lib/'):
        run('install_name_tool', '-delete_rpath', path, str(executable))
if '@executable_path/../Frameworks' not in paths:
    run('install_name_tool', '-add_rpath', '@executable_path/../Frameworks', str(executable))
licenses = contents / 'Resources' / 'licenses'
licenses.mkdir(parents=True, exist_ok=True)
shutil.copy2(root / 'LICENSE', licenses / 'PLANK-GPL.txt')
ffmpeg = licenses / 'ffmpeg'
ffmpeg.mkdir()
for source in args.ffmpeg_source.glob('COPYING*'):
    shutil.copy2(source, ffmpeg / source.name)
shutil.copy2(args.ffmpeg_source / 'LICENSE.md', ffmpeg / 'LICENSE.md')
shutil.copy2(args.opus_license, licenses / 'libopus-COPYING.txt')
shutil.copy2(args.sodium_license, licenses / 'libsodium-LICENSE.txt')
for binary in [*closure.values(), executable]:
    for dep in dependencies(binary):
        if not dep.startswith(('/System/Library/', '/usr/lib/', '@rpath/')):
            raise RuntimeError(f'Unbundled dependency in {binary.name}')
    run('codesign', '--force', '--sign', args.identity, '--options', 'runtime', '--timestamp=none', str(binary))
run('codesign', '--force', '--sign', args.identity, '--options', 'runtime', '--timestamp=none', str(args.output))
run('codesign', '--verify', '--deep', '--strict', str(args.output))
print(json.dumps({'bundle': str(args.output), 'source': info['PLANKSourceCommit'],
                  'version': info['CFBundleShortVersionString'], 'build': info['CFBundleVersion'],
                  'bundled_libraries': sorted(closure), 'signed_verified': True}, indent=2))
