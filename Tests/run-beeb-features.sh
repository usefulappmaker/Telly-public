#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
feature_test_dir="$(mktemp -d)"
trap 'rm -rf "$feature_test_dir"' EXIT
xcrun swiftc Shared/LiveChannels.swift Telly/BBCService.swift Tests/ResolverTests.swift -o "$feature_test_dir/resolver"
"$feature_test_dir/resolver"
xcrun swiftc Shared/LiveChannels.swift Telly/BBCService.swift Telly/Catalogue.swift Telly/Discovery.swift Telly/ITVCatalogue.swift Telly/ContinuousCatalogueStore.swift Tests/ContinuousCatalogueTests.swift -o "$feature_test_dir/continuous"
"$feature_test_dir/continuous"
xcrun swiftc Shared/LiveChannels.swift Telly/BBCService.swift Telly/Catalogue.swift Telly/PlaybackExtras.swift Telly/LiveSubtitles.swift Telly/LocalHLSServer.swift Telly/FMP4Normalizer.swift Tests/LiveSubtitleTests.swift -o "$feature_test_dir/captions"
"$feature_test_dir/captions" "$@"
xcrun swiftc Shared/LiveChannels.swift Telly/BBCService.swift Telly/Discovery.swift Telly/Catalogue.swift Telly/DASHManifest.swift Telly/LiveDASH.swift Telly/LocalHLSServer.swift Telly/FMP4Normalizer.swift Telly/ITVCatalogue.swift Tests/LiveDASHTests.swift -o "$feature_test_dir/live-uhd"
"$feature_test_dir/live-uhd"
xcrun swiftc Shared/LiveChannels.swift Telly/BBCService.swift Telly/Catalogue.swift Telly/UHDService.swift Tests/UHDTests.swift -o "$feature_test_dir/uhd"
"$feature_test_dir/uhd"
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj /CN=TellyFixture -keyout "$feature_test_dir/synthetic-key.pem" -out "$feature_test_dir/synthetic-cert.pem" > "$feature_test_dir/generation.log" 2>&1
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$feature_test_dir/synthetic-other-key.pem" >> "$feature_test_dir/generation.log" 2>&1
xcrun swiftc Shared/LiveChannels.swift Telly/BBCService.swift Telly/UHDIdentity.swift Telly/TwinVineDirectSetup.swift Telly/NativeIdentityPackage.swift Tests/NativeSetupTests.swift -o "$feature_test_dir/setup"
"$feature_test_dir/setup" "$feature_test_dir"
