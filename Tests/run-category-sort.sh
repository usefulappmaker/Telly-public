#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
sort_test_dir="$(mktemp -d)"
trap 'rm -rf "$sort_test_dir"' EXIT
xcrun swiftc Shared/LiveChannels.swift Telly/BBCService.swift Telly/Catalogue.swift Telly/Discovery.swift Telly/ITVCatalogue.swift Telly/UnifiedCategories.swift Tests/CategorySortTests.swift -o "$sort_test_dir/sort-tests"
"$sort_test_dir/sort-tests"
