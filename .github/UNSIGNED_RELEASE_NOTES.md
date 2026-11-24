Unsigned iPhoneOS build. Sign `Feather-unsigned.ipa` with your own certificate and provisioning profile before installing.

- From a signed app's **Update** menu, choose **Download Update & Re-sign** to download the source version and open it for signing. When the update is already in **Imported**, choose **Re-sign & Update**.
- Updates reuse the signed copy's saved name and bundle ID overrides, certificate, tweaks, and other signing settings. For copies signed before this release, Feather restores the name and bundle ID. Review the signing options and select any tweaks again in that case.
- Hosted uploads show the failing step, provider host, and HTTP status. Feather retries transient link checks, honors the provider's `Retry-After` window, and reuses successful uploads when you retry.
