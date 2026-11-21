#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
fixture_dir="$(mktemp -d)"
trap 'rm -rf "$fixture_dir"' EXIT
xcrun swiftc Shared/LiveChannels.swift Telly/BBCService.swift Telly/Catalogue.swift Telly/Discovery.swift Telly/ITVCatalogue.swift Telly/ITVAccount.swift Telly/ITVLive.swift Telly/UnifiedCategories.swift Telly/Channel5Service.swift Telly/Channel5Account.swift Telly/Channel4Catalogue.swift Telly/Channel4Playback.swift Telly/ChannelGuide.swift Tests/ChannelGuideTests.swift -o "$fixture_dir/channel-guide-tests"
"$fixture_dir/channel-guide-tests" "$@"
