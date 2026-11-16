Unsigned iPhoneOS build. Sign `Feather-unsigned.ipa` with your own certificate and provisioning profile before installing.

- Fix the 2.9.3 preflight regression that could block every server mode with “The local IPA endpoint is missing or empty.”
- Stop treating a HEAD response's expected body length as the IPA file size. Check the generated file directly and verify a real one-byte ranged GET instead.
- Match the returned byte and Content-Range to the generated file. Reject ignored ranges, oversized responses, wrong bytes and HTTP errors without downloading the IPA for preflight.
- Exercise the production probe using Foundation URLSession in CI, in addition to the existing curl, IPv4/IPv6 TLS and transport checks. Probes remain excluded from install progress and Safari dismissal.

Existing trusted CA profiles, hosted modes, per-bundle signing and user-managed patches are retained. No developer credentials, local CA keys or new tweak payloads are bundled. Device installation still requires a valid signature/profile and on-device confirmation.
