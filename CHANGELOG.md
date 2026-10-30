# Telly 0.8.1 — Playback hotfix

Changes since 0.8.0:

- **Fixed Channel 5 playback:** updated playback requests to address the HTTP 403 errors affecting live TV and catch-up.
- **Clearer Channel 5 errors:** request-signature failures no longer incorrectly suggest an account or location problem.
- **Channel 4 catch-up HD support:** updated playback requests to obtain HD-capable streams where available. Resolution varies by programme.
- **Updated regression tests** for Channel 5 playback requests and error handling.

Some Channel 5 catch-up programmes remain SD. The experimental iOS route is not included.

Downloads include matching source, an unsigned Apple TV IPA with Top Shelf, and SHA-256 checksums. To update an existing installation, retain its bundle identifier and sign with the same Apple account/team.

Build and automated checks passed; wider Apple TV testing is still needed.

---

# Changelog

## 0.8.0 public preview — build 35

First prepared public Telly edition, based on the current physical-device development build.

- Homepage headings share a consistent text size; network rows interleave, with extra cached Channel 4/Channel 5/U genre rows.
- Date/A-Z controls on BBC/ITV standard network pages, with alphabetical-only Channel 4/5/U/UHD pages and no control on mixed categories.
- Browse icons for Crime (fingerprint), Audio Described (speaker) and Travel (airplane), matching the existing category style.
- Re-select Browse to return to its main screen, matching Home root navigation.
- Five-provider catalogue: BBC, ITV, Channel 4, Channel 5 and U; merged categories, network badges and unified programme search.
- Mixed-network Featured banner, saved programmes and local Continue Watching.
- Discover BBC heading on Home, with BBC/ITV/Channel 4/Channel 5/U section logos matching Browse category heading sizes.
- BBC/ITV/Channel 4/Channel 5 live TV in the approved Freeview-style order, with regional extras and separate themed sections.
- Matching ordered Top Shelf sections, including Channel 5 launch routes.
- Account-code/QR linking for supported ITV, Channel 5 and U flows; native FairPlay integration on compatible streams.
- Latest-season default, newest-first soap browsing and chronological successor selection.
- Fifteen-second end-of-episode autoplay prompt with Cancel, Back and Play now.
- Native Info, speed controls and supported subtitles; BBC skip markers, regions, additional live streams and optional on-device UHD setup.
- Boxed Telly branding, stronger accessible RGB loading feedback and Home re-selection that returns from programme pages.

Known limits: Channel 4 currently SD; some Channel 5 catch-up assets SD; U live channels not integrated; subscription-only titles, downloads and cross-device sync are not supported. Native countdown focus and freshly changed navigation require wider device testing. The public signing route has not been tested under another person's account.
