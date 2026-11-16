Unsigned iPhoneOS build. Sign `Feather-unsigned.ipa` with your own certificate and provisioning profile before installing.

- Local CA (Offline) now serves the same minimal IPA-only manifest structure as the working hosted mode. Optional remote icon downloads are removed.
- Fully percent-encode nested installation URLs, including the localhost scheme and port.
- Validate the actual manifest response and local IPA HEAD response before Ready. HEAD and preflight requests no longer dismiss Safari or advance transfer progress.
- Keep the installation activity alive across Safari/system confirmation presentation changes, and make background audio startup idempotent.
- Test the production HTTP routes for delayed confirmation, HEAD probes, ranged/full IPA downloads, IPv4/IPv6 TLS and server shutdown.

Existing trusted Local CA profiles are preserved. Offline mode does not contact or silently fall back to a hosted plist service. Hosted Plist + Local CA remains available. Automated checks validate the transport and build; the reported device-specific installation failure cannot be considered resolved until confirmed on the device.

Includes the existing per-bundle signing, entitlement and user-managed IPApatch improvements. No developer signing identities, local CA keys or new tweak payloads are bundled.
