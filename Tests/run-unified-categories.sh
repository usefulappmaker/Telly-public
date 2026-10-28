#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
category_test_dir="$(mktemp -d)"
trap 'rm -rf "$category_test_dir"' EXIT
xcrun swiftc Shared/LiveChannels.swift Telly/BBCService.swift Telly/Catalogue.swift Telly/Discovery.swift Telly/ITVCatalogue.swift Telly/UnifiedCategories.swift Tests/UnifiedCategoryTests.swift -o "$category_test_dir/categories"
"$category_test_dir/categories"
xcrun swiftc Shared/LiveChannels.swift Telly/BBCService.swift Telly/Catalogue.swift Telly/Discovery.swift Telly/ITVCatalogue.swift Telly/UnifiedCategories.swift Tests/BBCMergedCategoryTests.swift -o "$category_test_dir/merged-bbc"
"$category_test_dir/merged-bbc"
