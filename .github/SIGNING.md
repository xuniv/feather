# Local installation, signing and patches

## Local HTTPS

In Settings → Installation, choose **Local CA (Offline)** and **Set Up Local CA**.
Safari downloads a configuration profile containing only this installation's
public root certificate. Install it in iOS Settings → General → VPN & Device
Management, then enable full trust in General → About → Certificate Trust
Settings. Return to Feather and use **Check Local CA Trust**.

The server binds to `127.0.0.1`. Its certificate includes localhost and the
loopback IP as SANs, uses an EC P-256 key and expires after 397 days. The root
private key is discarded after issuing the server certificate. The server key
and certificate are stored with restricted permissions in Application Support,
excluded from backups. Reset Local CA replaces that identity and requires
installing and trusting the replacement profile. Remove obsolete profiles in iOS
Settings. Reinstalling Feather also requires setup again.

Builds use the on-device CA by default and do not fetch TLS material. Pass
`BUNDLE_PUBLIC_TLS=1` to make to optionally bundle the public provider pack, or
use Update SSL Certificates in the app.

**Public TLS** retains the existing public certificate service, including its CA
chain. It depends on the provider publishing a current certificate. **Semi Local**
retains the external manifest service. Local CA mode needs neither service.

## Bundle identities and entitlements

Every executable `.app` and `.appex` gets a signing plan before signing begins.
The final `application-identifier` is the provisioning App ID Prefix plus the
actual bundle ID, even when the profile allows `PREFIX.*`. The prefix is not
assumed to equal TeamIdentifier. Keychain groups are remapped at identifier
boundaries and checked against the profile. Domain wildcards are not rewritten.

**Preserve Bundle Entitlements** defaults to enabled, including when loading old
presets. It reads entitlements independently from each bundle's executable.
Capabilities absent from its profile are removed with signing-log diagnostics
and a visible compatibility notice after signing;
explicitly requested unsupported custom capabilities cause an actionable error.
Custom entitlement files apply to the main app. An extension never receives the
main app's entitlement dictionary.

Add profiles for extensions in **Compatibility & Patches**. Exact bundle IDs win
over wildcard profiles. Every selected profile must have the same team and
include the selected signing certificate. Expired profiles/certificates and
unmatched bundle IDs stop signing. Each profile is embedded before its bundle's
resource seal is generated. Remove Provisioning applies to every planned bundle.

A valid signature cannot provision capabilities missing from an Apple profile.
App Groups, push notifications and remotely updated Live Activities require the
appropriate identifiers and profiles; a wildcard profile cannot invent them.
Document picker and Live Activity behavior still require device validation with
the target app. Renaming an app can also invalidate identifiers embedded in its
own code or remote service configuration.

## User-managed tweaks and IPApatch

Put `.deb` and `.dylib` files in **Documents/Tweaks**, then open **Choose from
Tweak Folder**. The existing Files importer remains available. Selected payloads
are copied into the signing copy, preserving originals for future signing.

The IPApatch system supports **Off**, **App and Extensions** and **Extensions
Only**. Choose an IPApatch-compatible runtime dylib from your folder or Files.
The system adds one runtime copy in the app's Frameworks directory and adds weak
load commands with relative paths from each target executable. zsign then signs
the runtime and all bundles. No patch/tweak catalog or runtime payload is added
by this feature. Compatibility of a particular runtime remains its author's
responsibility.

The existing automatic Substrate/ElleKit handling and manually selected tweak
injection remain available. Framework payloads now participate in extension
injection too. Separate extension processes use relative paths rather than
assuming the main process's rpath search list.

FFmpeg/Regram automatic fixes are service-specific. Compatible fixes can be
selected as user-managed deb/dylib files; this implementation does not bundle a
proprietary patch.

## Other compatibility controls

Identity/name/version/icon editing, appearance, minimum OS, Liquid Glass,
ProMotion, Game Mode, fullscreen, document browser, file sharing, URL scheme
removal, component selection and compression retain their existing controls.
Additional controls include duplicate identities, hiding the icon where iOS
supports it, opening documents in place, removing Watch apps/App Clips/all or
only encrypted extensions, optional supported-device removal, arm64 thinning,
and encryption-check override. An override does not decrypt binaries.

JIT requests `get-task-allow` only when permitted by every affected profile. It
does not activate JIT by itself. Ad-hoc signing recursively fakesigns binaries;
its output needs an environment which accepts ad-hoc code and is not an OTA
signature for a normal iOS device.

## Validation

Run `bash Tests/Signing/native.sh` for isolated, synthetic certificates, loopback
TLS checks and end-to-end bundle signing. The integration checks inspect XML/DER
entitlements, CMS signatures, code-page hashes, special slots, nested resource
seals, profile removal and certificate authorization. On macOS, a compiler-built
iOS fixture also receives an ad-hoc strict codesign verification; synthetic
certificates cannot satisfy the production Apple-anchor requirement.

Compile `Tests/Signing/main.swift` with EntitlementPolicy.swift and
MachOCompatibility.swift for identity, capability, wildcard, thinning and malformed
header regressions. The Validate Signing workflow runs these tests and builds
iOS without signing credentials. It does not upload certificates, provisioning
profiles, user payloads or device diagnostics.
