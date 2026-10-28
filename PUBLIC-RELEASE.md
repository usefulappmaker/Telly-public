# Public release boundary

This is an isolated source distribution, with no Git history, selected signing team, personal sessions or provisioning profiles. Public app/extension identifiers are templates. Preparing these files does not create a remote repository, release or social post.

Only publish this directory's checked source files after approval. Keep compiled IPAs outside source commits and attach the audited unsigned IPA and matching source ZIP as separate release assets. Keep LICENSE.txt and NOTICE.md. Choose an author name and GitHub noreply address before creating commits; do not import private development history.

Run `python3 scripts/check-public-release.py` before packaging. The scanner allows reviewed public catalogue JSON snapshots and synthetic fixtures. It rejects selected project teams, private key payloads, common tokens, account paths, unreviewed image metadata and unexpected file types. It is a practical release check, not an exhaustive anonymity guarantee.

The Channel 5 implementation contains public web-player metadata-envelope/signing parameters used for service requests. These are not user account sessions or media/DRM content keys. Channel 4 reads public player metadata-envelope parameters at runtime. Native FairPlay challenges/responses remain within each device's playback session; the app does not export raw media keys or copy browser licences.

Keep personal certificates, PKCS#12 packages, setup identities, account responses, QR pairing codes, Xcode user state, logs, device reports, broadcaster IPAs/APKs and imported media outside the source distribution. No repository, release asset or post is uploaded by the supplied scripts.
