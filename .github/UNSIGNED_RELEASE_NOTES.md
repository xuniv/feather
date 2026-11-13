Unsigned iPhoneOS build of Feather. Sign `Feather-unsigned.ipa` with your own certificate and provisioning profile before installing. No developer identity, provisioning profile, generated local CA, or server private key is included.

- Device-specific local HTTPS CA setup, with system trust checks and an offline default.
- Current zsign and OpenSSL sources; separate concrete identities, entitlements and profiles for apps and extensions.
- Ad-hoc signing preserves per-bundle entitlements without requiring provisioning profiles.
- Profile-restricted grants, including TestFlight beta reporting, are removed or rejected when unauthorized.
- IPApatch-compatible injection, explicit runtime choices, reusable `Documents/Tweaks`, cleanup and compatibility controls.

First use of Local CA mode requires profile installation and enabling certificate trust in iOS Settings. Document Picker and Live Activity behavior still depends on the target app and authorized capabilities. Individual tweak/runtime files are user-managed.

The release pipeline verifies that all packaged Mach-O files have no code signature or encryption, checks the IPA structure and version, and publishes `SHA256SUMS` alongside the download.
