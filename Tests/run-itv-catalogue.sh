#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
fixture_dir="$(mktemp -d)"
trap 'rm -rf "$fixture_dir"' EXIT
xcrun swiftc Shared/LiveChannels.swift Telly/BBCService.swift Telly/Catalogue.swift Telly/Discovery.swift Telly/ITVCatalogue.swift Telly/WatchHistory.swift Telly/Library.swift Tests/ITVCatalogueTests.swift -o "$fixture_dir/itv-tests"
"$fixture_dir/itv-tests" Telly/ITVCatalogueSeed.json
