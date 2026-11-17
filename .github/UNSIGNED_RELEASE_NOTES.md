Unsigned iPhoneOS build. Sign `Feather-unsigned.ipa` with your own certificate and provisioning profile before installing.

- Add an **Original IPA** tab for IPA files obtained with ipatool or another tool, following Asspp's original-package installation approach. It sends the original file to the existing installer without extraction, resigning, patching or repacking, preserving App Store signatures and license records.
- Original IPA installation requires a valid original signature and any required App Store license. Feather does not decrypt DRM, acquire licenses or add an Apple account. The signing Library remains available for decrypted apps.
- Store original imports separately, with an 8 GiB total limit; remove them after 24 hours or when Feather restarts. Active installations keep their imported file.
- Remove donation/sponsor banners from Settings and About while retaining original developer credits.
- Show the fork version as **2.9.0-5** (upstream 2.9.0, fork revision 5) in About and release titles. The numeric package version remains **2.9.5** for iOS/AltStore compatibility and update ordering. Track upstream and fork revisions separately for future merges.

The working 2.9.4 local installation transport and existing trusted CA profiles are retained. No account credentials, local CA keys or new tweak payloads are bundled. Original-package metadata/byte-preservation checks, signing regressions and an unsigned iOS build run before publication. Actual installation and App Store authorization are checked by iOS on the device.
