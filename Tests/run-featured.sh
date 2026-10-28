#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
featured_test_dir="$(mktemp -d)"
trap 'rm -rf "$featured_test_dir"' EXIT
xcrun swiftc Shared/LiveChannels.swift Telly/BBCService.swift Telly/Catalogue.swift Telly/Discovery.swift Telly/ITVCatalogue.swift Telly/UCatalogue.swift Telly/Channel5Service.swift Telly/Channel5Catalogue.swift Telly/FeaturedCatalogue.swift Tests/FeaturedTests.swift -o "$featured_test_dir/featured-tests"
"$featured_test_dir/featured-tests" "$@"
