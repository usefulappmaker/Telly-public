#!/usr/bin/env python3
"""Package a separately built unsigned tvOS app; never signs or uploads."""
import importlib.util
from pathlib import Path
import plistlib
import sys
import shutil
import subprocess
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]

def main():
    if len(sys.argv) != 2:
        raise SystemExit('Usage: make-unsigned-ipa.py path/to/Telly.app')
    app = Path(sys.argv[1]).resolve()
    if not app.is_dir() or app.suffix != '.app':
        raise SystemExit('Expected a built .app directory.')
    # Work on a disposable copy; never alter the installer's build product.
    staging = tempfile.TemporaryDirectory(prefix='telly-unsigned-')
    staged = Path(staging.name) / app.name
    shutil.copytree(app,staged)
    app = staged
    for bundle in [app] + list((app / 'PlugIns').glob('*.appex')):
        metadata = plistlib.loads((bundle / 'Info.plist').read_bytes())
        subprocess.run(['xcrun','strip','-S',str(bundle/metadata['CFBundleExecutable'])],check=True)
    info = plistlib.loads((app / 'Info.plist').read_bytes())
    version = info['CFBundleShortVersionString']
    destination = ROOT / 'dist' / f'Telly-{version}-public-unsigned.ipa'
    destination.parent.mkdir(exist_ok=True)
    with zipfile.ZipFile(destination,'w',zipfile.ZIP_DEFLATED) as archive:
        for path in sorted(app.rglob('*')):
            if path.is_symlink():
                destination.unlink(missing_ok=True)
                raise SystemExit('Symlinks are not accepted in the unsigned payload.')
            if not path.is_file():
                continue
            relative = path.relative_to(app)
            if '_CodeSignature' in relative.parts or path.suffix in {'.mobileprovision','.provisionprofile'}:
                destination.unlink(missing_ok=True)
                raise SystemExit('Input app contains a signature or provisioning profile. Build unsigned first.')
            if path.name == '.DS_Store' or any(part.startswith('._') for part in relative.parts):
                continue
            entry = zipfile.ZipInfo('Payload/' + app.name + '/' + relative.as_posix(),(1980,1,1,0,0,0))
            entry.create_system = 3
            entry.external_attr = (0o100000 | (0o755 if path.stat().st_mode & 0o111 else 0o644)) << 16
            entry.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(entry,path.read_bytes())
    spec = importlib.util.spec_from_file_location('unsigned_check',ROOT/'scripts/check-unsigned-ipa.py')
    checker = importlib.util.module_from_spec(spec); spec.loader.exec_module(checker)
    failures = checker.inspect(destination)
    if failures:
        destination.unlink(missing_ok=True)
        for failure in failures: print('FAIL:',failure)
        return 1
    print('Created dist/' + destination.name + '; unsigned payload checks passed.')
    return 0

if __name__ == '__main__':
    sys.exit(main())
