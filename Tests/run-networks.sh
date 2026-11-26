#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
network_test_dir="$(mktemp -d)"
trap 'rm -rf "$network_test_dir"' EXIT
xcrun swiftc Shared/LiveChannels.swift Telly/BBCService.swift Telly/Catalogue.swift Telly/Discovery.swift Telly/ITVCatalogue.swift Telly/NetworkSettings.swift Tests/NetworkSettingsTests.swift -o "$network_test_dir/network-tests"
"$network_test_dir/network-tests"
