#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
history_test_dir="$(mktemp -d)"
trap 'rm -rf "$history_test_dir"' EXIT
xcrun swiftc Shared/LiveChannels.swift Telly/BBCService.swift Telly/Catalogue.swift Telly/Discovery.swift Telly/ITVCatalogue.swift Telly/WatchHistory.swift Tests/WatchHistoryTests.swift -o "$history_test_dir/history-tests"
"$history_test_dir/history-tests"
