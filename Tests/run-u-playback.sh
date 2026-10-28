#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
u_test_dir="$(mktemp -d)"
trap 'rm -rf "$u_test_dir"' EXIT
xcrun swiftc Shared/LiveChannels.swift Telly/BBCService.swift Telly/Catalogue.swift Telly/Discovery.swift Telly/ITVCatalogue.swift Telly/UCatalogue.swift Telly/UService.swift Telly/UAccount.swift Tests/UPlaybackTests.swift -o "$u_test_dir/u-playback-tests"
"$u_test_dir/u-playback-tests" "$@"
