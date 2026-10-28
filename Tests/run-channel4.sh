#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
fixture_dir="$(mktemp -d)"
trap 'rm -rf "$fixture_dir"' EXIT
xcrun swiftc Shared/LiveChannels.swift Telly/BBCService.swift Telly/Catalogue.swift Telly/Discovery.swift Telly/ITVCatalogue.swift Telly/Channel4Catalogue.swift Telly/Channel4Playback.swift Tests/Channel4Tests.swift -o "$fixture_dir/channel4-tests"
"$fixture_dir/channel4-tests" "$@"
