#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
channel5_test_dir="$(mktemp -d)"
trap 'rm -rf "$channel5_test_dir"' EXIT
xcrun swiftc Shared/LiveChannels.swift Telly/BBCService.swift Telly/Catalogue.swift Telly/Discovery.swift Telly/ITVCatalogue.swift Telly/UnifiedCategories.swift Telly/Channel5Service.swift Telly/Channel5Account.swift Telly/Channel5Catalogue.swift Telly/Channel5Playback.swift Tests/Channel5Tests.swift -o "$channel5_test_dir/channel5-tests"
"$channel5_test_dir/channel5-tests" "$@"

xcrun swiftc Telly/Channel5Service.swift Telly/Channel5Account.swift Tests/Channel5PairingTests.swift -o "$channel5_test_dir/pairing-tests"
"$channel5_test_dir/pairing-tests"
