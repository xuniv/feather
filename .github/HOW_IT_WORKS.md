## How does it work?

How Feather works is a bit complicated, with having multiple ways to install, app management, tweaks, etc. However, I'll point out how the important features work here.

To start off, we need a validly signed IPA. We can achieve this with Zsign, using a provided IPA using a `.p12` and `.mobileprovision` pair.

#### Install (Server)

Feather packages the signed app and starts a local server only for server installation. Export and pairing installation do not start it or require a CA. Before reporting Ready, Feather checks the actual local connection with system TLS trust and, for hosted modes, fetches and validates the HTTPS manifest response.

Installation opens a local page in Safari with an `itms-services://?action=download-manifest&url=...` link. The page tries automatic handoff and provides an Install link if a user gesture is required. This route is used in all server modes, including Local CA, to accommodate iOS restrictions on launching installation from the app. The Safari sheet closes when IPA transfer starts.

- **Local CA (Offline):** The manifest, IPA and installation page use HTTPS on device loopback. Install the generated CA profile and enable full trust in iOS Settings once. New identities cover `feather.localhost`, `localhost`, `127.0.0.1` and `::1`. IPv4 and IPv6 loopback listeners support localhost resolution without exposing HTTPS to the LAN. If a preferred hostname does not resolve, a covered localhost/IP address is tried.
- **Hosted Plist (HTTP):** Restores the former Semi Local route. The HTTPS [plistserver](https://github.com/nekohaxx/plistserver) service generates the manifest; the IPA and Safari page use the device's HTTP server. A Local CA is not needed. The localhost-only switch selects loopback instead of the device's LAN address; failed LAN preflight falls back to loopback.
- **Public TLS:** Uses downloaded public TLS credentials and a loopback-resolving hostname. Expired credentials must be updated in Installation settings.
- **Hosted Plist + Local CA:** Uses the hosted HTTPS manifest with a locally trusted HTTPS IPA endpoint.

Hosted modes send the service the app's name, bundle ID, build version and local IPA URL; IPA contents, developer certificates and local private keys remain on the device. The service URL is configurable and must use HTTPS. Query values are URL-encoded once at each nesting level and XML-escaped for the upstream plistserver API. The returned manifest must identify the selected app, build and exact local payload URL before installation can continue.

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