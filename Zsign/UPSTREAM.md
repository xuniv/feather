# zsign sources

The native signing core is vendored from
[zhlynn/zsign](https://github.com/zhlynn/zsign), commit
`9299685bab7ef99827e06e5dfda93af747386590`.
See LICENSE for the upstream license. The source commit is pinned so a clean
checkout builds the same signing engine without an unpublished submodule commit.

The Swift and Objective-C adapters are retained from
[khcrysalis/Zsign-Package](https://github.com/khcrysalis/Zsign-Package), commit
`c4ba9da4283031c07efa03bce42c4b8602d22e73`.

Local changes to the native core:

- Namespace requirement-type constants to coexist with Apple Security headers.
- Retain Feather's dylib listing and load-path replacement APIs; always terminate
  replacement paths with NUL, including lengths divisible by eight.
- Add an explicit bundle-path-to-signing-asset map to ZBundle. Each app/extension
  receives its own normalized entitlements and profile before resource sealing.
- Expose the signing certificate read-only for the adapter's certificate check.
- Release owned OpenSSL assets and prevent accidental owning copies.
- Flush and unmap Mach-O edits before releasing architecture objects.
- Check leaf certificate validity and membership in DeveloperCertificates.

The adapter supports every embedded WWDR generation through the upstream lookup,
extracts provisioning content through CMS decoding, propagates immediate signing
failure, and disables the disk signing cache. The local TLS generator in swift/
is separate from app signing and produces loopback-only certificates.

No tweak payloads, signing identities, provisioning profiles, or credentials are
included. IPApatch-compatible runtime selection is user-managed. The injection
layout follows [asdfzxcvbn/ipapatch](https://github.com/asdfzxcvbn/ipapatch);
no binary from that project is distributed here.
