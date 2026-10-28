#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
u_test_dir="$(mktemp -d)"
trap 'rm -rf "$u_test_dir"' EXIT
xcrun swiftc Shared/LiveChannels.swift Telly/BBCService.swift Telly/Catalogue.swift Telly/Discovery.swift Telly/ITVCatalogue.swift Telly/UnifiedCategories.swift Telly/UCatalogue.swift Tests/UCatalogueTests.swift -o "$u_test_dir/u-tests"
"$u_test_dir/u-tests" "$@"
