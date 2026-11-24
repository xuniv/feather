Unsigned iPhoneOS build. Sign `Feather-unsigned.ipa` with your own certificate and provisioning profile before installing.

- Open the iOS installation confirmation directly in **Local CA (Offline)**, using the same `itms-services` handoff as Asspp. Feather runs its local HTTPS, manifest and IPA checks before asking iOS to open the link.
- **Bypass Safari Web View** is enabled by default in Installation settings for Local CA (Offline). Turn it off to use the Safari installation page. The default server uses `feather.localhost` and can use a compatible loopback address with an existing trusted CA.
- The direct installation flow is available for both the Library and Original IPA tab. Saved installation settings and trusted CA profiles carry forward when updating.
