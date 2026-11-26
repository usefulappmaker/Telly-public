#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
library_test_dir="$(mktemp -d)"
trap 'rm -rf "$library_test_dir"' EXIT
xcrun swiftc Shared/LiveChannels.swift Telly/BBCService.swift Telly/Catalogue.swift Telly/Discovery.swift Telly/ITVCatalogue.swift Telly/Profiles.swift Telly/Library.swift Tests/LibraryTests.swift -o "$library_test_dir/library-tests"
"$library_test_dir/library-tests"
