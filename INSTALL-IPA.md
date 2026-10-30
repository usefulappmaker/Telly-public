# Sign and install the unsigned IPA

**Telly-0.8.1-public-unsigned.ipa** contains a prebuilt physical-tvOS arm64 app and its Top Shelf extension. It is intentionally unsigned and has no provisioning profile. It cannot be installed directly.

Use a signing/install workflow that explicitly supports tvOS and nested app extensions. Supply your own Apple signing identity and valid tvOS provisioning for both the app and its matching `.TopShelf` extension. If you change identifiers, update both consistently and preserve the app-specific Keychain entitlement. Do not use an iOS-only signing profile or drop the extension from the package.

Verify the IPA's SHA-256 against the supplied checksum before signing. After signing, use your chosen supported Apple TV installation workflow. If that workflow cannot sign nested tvOS extensions, [build and run from Xcode](INSTALL.md) instead; it is the supported fallback.

The unsigned artifact has been structurally checked, but installation under another person's signing account has not been verified. The simulator does not establish FairPlay playback compatibility. Apple account limits and provisioning expiry still apply.
