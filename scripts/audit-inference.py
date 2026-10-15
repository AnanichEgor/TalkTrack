#!/usr/bin/env python3
"""Check the actual Xcode graph, linked binaries, and local inference entry points.

Usage: python3 scripts/audit-inference.py <successful-xcodebuild-log>
This is a static integration check, not an offline model-inference test.
"""
import json
from pathlib import Path
import re
import subprocess
import sys

root = Path(__file__).resolve().parent.parent
log = Path(sys.argv[1]).read_text()
assert '** BUILD SUCCEEDED **' in log, 'A successful build log is required.'
targets = set(re.findall(r"^    Target '([^']+)' in project", log, re.MULTILINE))
assert targets, 'No compiled target graph found.'
required = {'MLX', 'MLXLLM', 'MLXAudioSTT', 'TalkTrackSpeakerMLX', 'Tokenizers'}
assert required <= targets, f'Missing targets: {required - targets}'
forbidden = {'Generation', 'Models', 'Transformers-product', 'WhisperKit', 'FluidAudio', 'PythonKit'}
assert not targets & forbidden, f'Alternate inference targets: {targets & forbidden}'

for tree in [root / 'App', root / 'Packages']:
    for file in tree.rglob('*.swift'):
        if '.build' in file.parts:
            continue
        source = file.read_text()
        assert not re.search(r'^\s*(?:@\w+\s+)?import\s+(CoreML|WhisperKit|FluidAudio|PythonKit)\b', source, re.MULTILINE), file
        assert 'fromPretrained(' not in source, f'Downloader entry point: {file}'

app = root / '.build/xcode/Build/Products/Debug/TalkTrack.app'
binaries = list((app / 'Contents/MacOS').glob('*'))
for binary in binaries:
    if not binary.is_file():
        continue
    libraries = subprocess.check_output(['otool', '-L', str(binary)], text=True)
    assert not re.search(r'CoreML|WhisperKit|libpython|libggml|libllama', libraries, re.IGNORECASE), binary

pins = json.loads((root / 'TalkTrack.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved').read_text())['pins']
identities = {pin['identity'] for pin in pins}
assert not identities & {'fluidaudio', 'whisperkit', 'llama.cpp', 'pythonkit'}
print(f'PASS: {len(targets)} build targets, {len(binaries)} application binaries; no alternate inference engine found.')
print('Local Qwen loaders only. Checkpoint execution, model-path confinement, and offline behavior remain separate gates.')
