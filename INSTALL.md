# Install Telly from source

You need a Mac with full Xcode and compatible tvOS platform support, an Apple signing account, and a physical Apple TV running tvOS 17 or later. Protected playback needs a physical device; the simulator is useful for interface/build checks. Apple TV 4K and a suitable HLG display connection are needed for compatible BBC 4K HLG content.

1. Extract the public source ZIP and open **Telly.xcodeproj**.
2. Add your Apple account in Xcode Settings → Accounts.
3. Select both **Telly** and **TellyTopShelf** under Signing & Capabilities. Enable automatic signing and select your own team. No team is preselected in this source distribution.
4. Set **TELLY_APP_BUNDLE_IDENTIFIER** to a unique identifier, such as `com.youralias.Telly`, in Debug and Release. The extension identifier follows as `.TopShelf`. Leave the app-specific Keychain entitlement in place.
5. Pair your Apple TV through Xcode's device window/Device Hub and the Apple TV's Remote App and Devices screen. Choose your physical TV as the Telly scheme destination.
6. Press Run. Follow any device-development prompts Xcode presents.
7. Open a programme to check playback. Link your own provider account when prompted. Optional BBC UHD setup is in Settings → Enable BBC UHD.

A free Personal Team can require frequent re-signing; paid profiles also expire. Keep your team and bundle identifier unchanged when updating your own build to retain access to the same local data and Keychain sessions. The public build uses a separate identifier from the maintainer's development app, so it does not inherit the maintainer's sign-ins or viewing history.

Move Telly to the top row of the Apple TV home screen to use live-channel Top Shelf cards. The system may refresh these independently of the app.

No App Store/TestFlight release or shared developer account is supplied. Playback remains subject to provider availability and account/region requirements.
