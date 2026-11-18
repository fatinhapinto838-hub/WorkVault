#!/usr/bin/env python3
"""Compile and run isolated, synthetic Store.rpc pagination/search benchmarks."""
import json
import os
from pathlib import Path
import subprocess

project = Path(__file__).resolve().parents[1]
build = project / '.build'
build.mkdir(exist_ok=True)
legacy = Path('/Library/Developer/CommandLineTools/usr/include/swift/module.modulemap')
current = legacy.with_name('bridging.modulemap')
extra = []
if legacy.exists() and current.exists():
    empty = build / 'benchmark-empty.modulemap'
    empty.write_text('')
    overlay = build / 'benchmark-overlay.json'
    overlay.write_text(json.dumps({'version': 0, 'roots': [
        {'type': 'file', 'name': str(legacy), 'external-contents': str(empty)}]}))
    extra = ['-vfsoverlay', str(overlay), '-Xcc', '-ivfsoverlay', '-Xcc', str(overlay)]
cache = os.environ.get('WORKVAULT_MODULE_CACHE', str(build / 'module-cache'))
executable = build / 'WorkVaultBenchmark'
subprocess.run(['/usr/bin/swiftc', '-O', *extra, '-module-cache-path', cache,
    '-I', str(project / 'CSQLite'), str(project / 'Sources/DB.swift'),
    str(project / 'Sources/Store.swift'), str(project / 'Sources/Deliverables.swift'), str(project / 'Tests/Benchmark.swift'),
    '-o', str(executable)], cwd=project, check=True)
result = subprocess.run([str(executable)], cwd=project, capture_output=True, text=True, check=True)
parsed = json.loads(result.stdout)
output = project / 'Tests/results/benchmark-results.json'
output.parent.mkdir(exist_ok=True)
output.write_text(json.dumps(parsed, ensure_ascii=False, indent=2)+'\n')
print(output)
for data in parsed['datasets']:
    print(f"\n{data['metadata_files']} metadata files, 50 projects, 1 real shared blob")
    for metric in data['measurements']:
        print(f"{metric['operation']}: median {metric['median_ms']:.3f} ms, p95 {metric['p95_ms']:.3f} ms")
