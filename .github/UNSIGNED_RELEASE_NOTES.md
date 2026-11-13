Unsigned iPhoneOS build of Feather. Sign `Feather-unsigned.ipa` with your own certificate and provisioning profile before installing.

- Fix installation remaining at Ready: generate the required `itms-services://?` URL and open a Safari handoff page in every server mode, with a manual Install link.
- Restore Hosted Plist (HTTP), fix nested URL/XML encoding, and validate the hosted manifest before handoff. Add a configurable HTTPS plist server and Hosted Plist + Local CA mode.
- Support `feather.localhost`, IPv4 and IPv6 loopback HTTPS. Reuse older trusted Local CA identities through `localhost`; no automatic CA reset.
- Check real local connectivity before Ready and display connection, trust and hosted-server errors. Export and pairing no longer initialize the TLS server.

Existing Local CA users can keep their trusted profile. To use `feather.localhost` with a CA generated before this version, explicitly reset the CA and install/trust its replacement; otherwise `localhost` is selected automatically. Hosted Plist (HTTP) works without a Local CA. If Safari does not open the install prompt automatically, tap Install on the page. Actual installation still depends on iOS policy and a valid signature/profile; automated tests cannot replace testing on your device.

Includes the previous per-bundle signing, entitlement and user-managed IPApatch improvements. No new tweak payloads, developer signing identities or generated local CA/private keys are included. The pipeline verifies all packaged Mach-O files are unsigned and publishes `SHA256SUMS` alongside the IPA.
