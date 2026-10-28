#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
search_test_dir="$(mktemp -d)"
trap 'rm -rf "$search_test_dir"' EXIT
xcrun swiftc -O Shared/LiveChannels.swift Telly/BBCService.swift Telly/Catalogue.swift Telly/Discovery.swift Telly/ITVCatalogue.swift Telly/CatalogueIndex.swift Telly/Channel4Catalogue.swift Telly/Channel4Playback.swift Telly/Channel5Service.swift Telly/Channel5Catalogue.swift Telly/CatalogueSearchModel.swift Tests/CatalogueSearchTests.swift -o "$search_test_dir/search-tests"
"$search_test_dir/search-tests"
