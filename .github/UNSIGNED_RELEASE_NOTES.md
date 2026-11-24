Unsigned iPhoneOS build. Sign `Feather-unsigned.ipa` with your own certificate and provisioning profile before installing.

- Long-press a signed app in Library and choose **Upload for Install**. Feather prepares the IPA, displays its compressed size, and disables hosts whose limits it exceeds. After an explicit upload, Feather verifies the direct HTTPS IPA link, uploads an XML property-list manifest, and offers the `itms-services` link to copy or open.
- **Upload for Share** on an imported app uploads the IPA and provides its direct download link. The system Share option is available separately. Standard local installation and signed export are still available.
- Litterbox is the default and supports 1, 12, 24, and 72 hours. Its manifest upload uses an .xml filename so it is served as text/xml. 0x0.st uses its documented multipart fields and identifies Feather with its version and bundle ID.
- Upload provider rules are bundled from the root `upload-providers.json` and refreshed from the public feed every seven days when the app is active. **Settings → Upload Providers** supports adding or replacing feed URLs and refreshing immediately.

Install links work while both hosted files are available. iOS still validates the IPA signature and provisioning profile on the target device. The direct Local CA Offline handoff introduced in 2.9.0-6 remains available for local installs.
