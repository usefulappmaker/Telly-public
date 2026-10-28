# Development

Open the Xcode project and select Telly. Public source uses `com.example.Telly` as a signing template. Configure your own team/identifier before device installation.

Unsigned physical-device build:

```sh
xcodebuild -project Telly.xcodeproj -scheme Telly -configuration Release \
  -sdk appletvos -destination 'generic/platform=tvOS' \
  -derivedDataPath build/device CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' DEVELOPMENT_TEAM='' \
  DEBUG_INFORMATION_FORMAT=dwarf build
```

Useful focused checks:

```sh
bash Tests/run-category-sort.sh
bash Tests/run-watch-history.sh
bash Tests/run-featured.sh
bash Tests/run-unified-categories.sh
bash Tests/run-itv-catalogue.sh
bash Tests/run-channel4.sh
bash Tests/run-channel5.sh
bash Tests/run-u.sh
bash Tests/run-u-playback.sh
bash Tests/run-search.sh
xcrun swiftc Shared/LiveChannels.swift Tests/LiveChannelsTests.swift -o /tmp/telly-live-check
/tmp/telly-live-check
python3 -m unittest discover -s Tests -p 'test_public_release.py'
python3 scripts/check-public-release.py
```

Tests that offer `--network` contact public provider metadata services; use those separately from the default offline fixtures. No test should require a personal account session committed to the tree.

Create the source archive with `python3 scripts/make-public-archive.py`. To package a previously built unsigned app use `python3 scripts/make-unsigned-ipa.py build/device/Build/Products/Release-appletvos/Telly.app`; the tool rejects signatures/profiles instead of copying a personally signed app.
