## How does it work?

How Feather works is a bit complicated, with having multiple ways to install, app management, tweaks, etc. However, I'll point out how the important features work here.

To start off, we need a validly signed IPA. We can achieve this with Zsign, using a provided IPA using a `.p12` and `.mobileprovision` pair.

#### Install (Server)

Feather packages the signed app and starts a local server only for server installation. Export and pairing installation do not start it or require a CA. Before reporting Ready, Feather checks the actual local connection with system TLS trust, fetches and validates the selected manifest in every mode, and reads the generated file size/first byte and verifies a one-byte ranged GET from the actual IPA endpoint. The probe checks Content-Range and returned bytes, never HEAD expectedContentLength. These preflight/HEAD requests do not start installation progress or dismiss Safari.

With **Local CA (Offline)**, Feather opens the validated manifest through `UIApplication.open` and the `itms-services://` scheme to request the iOS installation confirmation directly. This is the default flow and uses `feather.localhost` as the preferred loopback address. The **Bypass Safari Web View** toggle in Installation settings is on by default. Turn it off to use the Safari handoff page, which offers an Install link if iOS requires a user gesture. Other server modes use the Safari page. The local server stays active during the system confirmation and package download.

- **Local CA (Offline):** The manifest, IPA and installation page use HTTPS on device loopback. The local manifest uses the same minimal software-package asset structure as the hosted plist service, avoiding separate optional icon fetches. Install the generated CA profile and enable full trust in iOS Settings once. New identities cover `feather.localhost`, `localhost`, `127.0.0.1` and `::1`. IPv4 and IPv6 loopback listeners support localhost resolution without exposing HTTPS to the LAN. If a preferred hostname does not resolve, a covered localhost/IP address is tried.
- **Hosted Plist (HTTP):** Restores the former Semi Local route. The HTTPS [plistserver](https://github.com/nekohaxx/plistserver) service generates the manifest; the IPA and Safari page use the device's HTTP server. A Local CA is not needed. The localhost-only switch selects loopback instead of the device's LAN address; failed LAN preflight falls back to loopback.
- **Public TLS:** Uses downloaded public TLS credentials and a loopback-resolving hostname. Expired credentials must be updated in Installation settings.
- **Hosted Plist + Local CA:** Uses the hosted HTTPS manifest with a locally trusted HTTPS IPA endpoint.

Hosted modes send the service the app's name, bundle ID, build version and local IPA URL; IPA contents, developer certificates and local private keys remain on the device. The service URL is configurable and must use HTTPS. The entire manifest URL (including its scheme and port) is percent-encoded once inside the installation URL. API query values are URL-encoded once at each nesting level and XML-escaped for the upstream plistserver API. The returned manifest must identify the selected app, build and exact local payload URL before installation can continue.

An existing trusted 2.9.1 CA is preserved: its certificate already covers `localhost` and `127.0.0.1`, so these work without replacing the profile. Adding `feather.localhost` to that certificate requires explicitly choosing Reset Local CA and installing/trusting the replacement profile. The CA private key was discarded when the original identity was generated and is not retained by Feather.

#### Install (Pairing)
- Establish a heartbeat with a TCP provider (the app will need this for later).
  - For it to be successful, we need a pairing file from [PlumeImpactor](https://github.com/khcrysalis/Impactor?tab=readme-ov-file#pairing-file) and a [VPN](https://apps.apple.com/us/app/localdevvpn/id6755608044).
- Once we have these and the connection was successfully established, we can move on to the installation part.
  - Before installing, we need to check for the connection to the socket that has been created, routed to `10.7.0.1`, if this succeeds we're ready.
- When preparing for installation, we need to establish another connection but for `AFC` using the TCP provider.
- Once the connection was established we need to created a staging directory to `/PublicStaging/` and upload our IPA there.
- Then, using our connection to `AFC` we can command it to install that IPA directly. Similar to `ideviceinstaller`, but fully on your phone.

Due to how it works right now we need both a VPN and a lockdownd pairing file, this means you will need a computer for its initial setup. Though, if you don't want to do these you can just use the server way of installing instead (but at a cost of less reliability).
#### Original IPA installation

The separate **Original IPA** tab accepts IPA files from ipatool or other tools. It reads only one bounded main-app Info.plist (up to 1 MiB), copies the archive as an opaque file, and passes that same file to the existing server/pairing installer. It does not run ArchiveHandler's move/archive steps or the signing/patching pipeline. Nested signatures, SC_Info/SINF records and encrypted executables remain byte-for-byte intact. OTA metadata uses the original CFBundleVersion. iOS still requires valid original signatures and the necessary App Store licenses; this workflow does not decrypt or authorize packages.

Imports are separate from the signing Library, capped at 8 GiB total, and expire after 24 hours or restart. A selected installation retains its file until the installation sheet closes. English and Korean UI text explain the original-package path. See [fork maintenance](FORK_MAINTENANCE.md) for public fork versions and future upstream merges.

#### Hosted IPA uploads

Long-press a signed app and select **Upload for Install**, or an imported app and select **Upload for Share**. The sheet displays the exact archived size and the selected upload destination. Uploads start when you tap Upload. A signed IPA can include a provisioning profile with registered-device information. Anyone with the resulting links can retrieve the hosted files until expiry.

The installer checks the uploaded IPA with a small ranged GET and serves no data from Feather. It generates the manifest from the uploaded URL and the archive's actual bundle ID and build version. The manifest is an XML plist. Litterbox uses an .xml filename to return the correct XML content type. Feather compares the downloaded manifest with the bytes it uploaded and rejects redirects. If the manifest step fails, Retry uses the existing IPA link while it remains available. Sharing an imported IPA only requires the IPA upload.

**Settings → Upload Providers** manages HTTPS JSON lists. The default list comes from [the fork's upload-providers.json](https://raw.githubusercontent.com/xuniv/feather/main/upload-providers.json). Add a feed, tap a URL to replace it, or select **Refresh Now**. The app checks sources every seven days on activation, retains the last valid rules through refresh failures, and ships with the fork list for offline use. For duplicate provider IDs, the first configured list takes priority.

The version 1 schema defines each provider's HTTPS multipart POST URL, file field, fixed fields, file name extensions, per-file limit, and optional total request limit. Options map a selected choice to additional multipart fields. The response can be a plain HTTPS URL or a URL property in JSON described by its key path. Downloads must use an allowed host and the declared XML MIME types for manifests. The `ua` upload field accepts a literal string, `true` for `Feather/<fork-version> (<bundle-id>)`, or missing, `false`, or `null` for `curl`.
