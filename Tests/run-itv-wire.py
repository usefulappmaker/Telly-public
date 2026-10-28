#!/usr/bin/env python3
"""Run wire-format fixtures against the helpers used by the test app."""
from pathlib import Path
import subprocess
import tempfile
root = Path(__file__).resolve().parents[1]
source = (root / 'Telly/ITVPlaybackTest.swift').read_text()
helpers = source[source.index('struct ITVProbeError:'):source.index('final class ITVProbeHTTP:')]
checks = (root / 'Tests/ITVWireChecks.swift').read_text()
with tempfile.TemporaryDirectory(prefix='telly-itv-fixtures-') as folder:
    script = Path(folder) / 'main.swift'
    script.write_text('import Foundation\n' + helpers + checks)
    subprocess.run(['swift', str(script)], check=True)
