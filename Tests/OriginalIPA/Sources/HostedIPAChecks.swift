import Foundation
import ZIPFoundation

func checkHostedIPA(catalogFile: URL) async throws {
    let catalogData = try Data(contentsOf: catalogFile)
    let catalog = try UploadProviderCatalog.decode(catalogData)
    guard let litterbox = catalog.providers.first(where: { $0.id == "litterbox" }),
          let nullPointer = catalog.providers.first(where: { $0.id == "0x0-st" }) else {
        fatalError("Missing bundled upload providers")
    }
    precondition(catalog.defaultProvider == litterbox.id)
    precondition(UploadProviderCatalog.refreshInterval == 7 * 24 * 60 * 60)
    precondition(litterbox.userAgent(bundleID: "example.feather", version: "2.9.0-7") == "curl")
    precondition(nullPointer.userAgent(bundleID: "example.feather", version: "2.9.0-7") == "Feather/2.9.0-7 (example.feather)")
    let defaultLitterboxFields = try litterbox.fields(choices: [:])
    precondition(defaultLitterboxFields == ["reqtype": "fileupload", "time": "1h"])
    let nullPointerFields = try nullPointer.fields(choices: ["retention": "72h"])
    precondition(nullPointerFields == ["expires": "72", "secret": ""])
    precondition(!HostedIPAMultipart.accepts(size: nullPointer.fileLimitBytes, provider: nullPointer, choices: [:]))
    precondition(HostedIPAMultipart.accepts(size: nullPointer.fileLimitBytes - 2_048, provider: nullPointer, choices: [:]))

    func variant(ua: Any?, format: [String: Any] = ["format": "plainTextURL"],
                 endpoint: String? = nil) throws -> UploadProviderCatalog {
        var json = try JSONSerialization.jsonObject(with: catalogData) as! [String: Any]
        var providers = json["providers"] as! [[String: Any]]
        var upload = providers[0]["upload"] as! [String: Any]
        upload["ua"] = ua
        upload["response"] = format
        if let endpoint { upload["url"] = endpoint }
        providers[0]["upload"] = upload
        json["providers"] = providers
        return try UploadProviderCatalog.decode(JSONSerialization.data(withJSONObject: json))
    }
    for ua: Any? in [nil, NSNull(), false, true, "CustomTest/1.0"] {
        let provider = try variant(ua: ua).providers[0]
        let agent = provider.userAgent(bundleID: "example.feather", version: "2.9.0-7")
        if let literal = ua as? String { precondition(agent == literal) }
        else if ua as? Bool == true { precondition(agent == "Feather/2.9.0-7 (example.feather)") }
        else { precondition(agent == "curl") }
    }
    let jsonProvider = try variant(ua: false,
        format: ["format": "jsonURL", "path": ["data", "download_url"]]).providers[0]
    let parsedURL = try jsonProvider.downloadURL(from: Data(#"{"data":{"download_url":"https://litter.catbox.moe/test.xml"}}"#.utf8))
    precondition(parsedURL.absoluteString == "https://litter.catbox.moe/test.xml")
    expectFailure { _ = try variant(ua: "Not\r\nAHeader") }
    expectFailure { _ = try variant(ua: false, endpoint: "http://example.test/upload") }
    expectFailure { _ = try UploadProviderCatalog.sourceURL("file:///private/upload-providers.json") }
    expectFailure { _ = try UploadProviderCatalog.sourceURL("https://name:password@example.test/providers.json") }
    try checkFile2Me(catalog: catalog, catalogData: catalogData)

    let manager = FileManager.default
    let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let app = root.appendingPathComponent("Example.app", isDirectory: true)
    let seals = app.appendingPathComponent("_CodeSignature", isDirectory: true)
    try manager.createDirectory(at: seals, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: root) }

    let info: [String: Any] = [
        "CFBundleIdentifier": "example.hosted", "CFBundleDisplayName": "Hosted & Test",
        "CFBundleShortVersionString": "1.5", "CFBundleVersion": "731",
        "CFBundleSupportedPlatforms": ["iPhoneOS"]
    ]
    let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
    try plist.write(to: app.appendingPathComponent("Info.plist"))
    let codeResources = Data("test signature seal".utf8)
    try codeResources.write(to: seals.appendingPathComponent("CodeResources"))
    try manager.createSymbolicLink(atPath: app.appendingPathComponent("SealLink").path,
                                   withDestinationPath: "_CodeSignature/CodeResources")

    let signed = try await HostedIPAArchive.prepare(app: app, forInstallation: true)
    guard let metadata = signed.metadata else { fatalError("Missing signed archive metadata") }
    precondition(metadata.identifier == "example.hosted" && metadata.version == "731" && metadata.name == "Hosted & Test")
    let package = try Archive(url: signed.file, accessMode: .read)
    guard let seal = package["Payload/Example.app/_CodeSignature/CodeResources"],
          let link = package["Payload/Example.app/SealLink"], link.type == .symlink else {
        fatalError("Hosted package lost its seal or symlink")
    }
    var extracted = Data()
    _ = try package.extract(seal) { extracted.append($0) }
    precondition(extracted == codeResources)

    let shared = try await HostedIPAArchive.prepare(app: app, forInstallation: false)
    precondition(shared.metadata == nil)
    precondition(signed.size > 0 && signed.size < litterbox.fileLimitBytes)
    precondition(litterbox.options.first?.choices.map(\.id) == ["1h", "12h", "24h", "72h"])
    precondition(litterbox.accepts(size: litterbox.fileLimitBytes))
    precondition(!litterbox.accepts(size: litterbox.fileLimitBytes + 1))

    let ipaURL = try litterbox.downloadURL(from: Data("https://litter.catbox.moe/example.ipa\n".utf8))
    let manifest = try PropertyListSerialization.data(
        fromPropertyList: InstallationTransport.manifest(metadata: metadata, payload: ipaURL),
        format: .xml, options: 0)
    try InstallationTransport.validateManifest(manifest, metadata: metadata, payload: ipaURL)
    let plistFile = root.appendingPathComponent("install.plist")
    try manifest.write(to: plistFile)
    let manifestURL = try litterbox.downloadURL(from: Data("https://litter.catbox.moe/example.xml".utf8))
    let linkURL = InstallationTransport.installationURL(manifest: manifestURL)
    let query = URLComponents(url: linkURL, resolvingAgainstBaseURL: false)?.queryItems
    precondition(query?.first(where: { $0.name == "url" })?.value == manifestURL.absoluteString)

    for (file, kind, filename) in [
        (signed.file, HostedIPAMultipart.FileKind.ipa, "App.ipa"),
        (plistFile, .manifest, "install.xml")
    ] {
        let request = try HostedIPAMultipart.write(file: file, kind: kind, provider: litterbox, choices: ["retention": "12h"])
        defer { try? manager.removeItem(at: request.url) }
        let data = try Data(contentsOf: request.url)
        let payload = try Data(contentsOf: file)
        let prefix = Data(("--\(request.boundary)\r\n" +
            "Content-Disposition: form-data; name=\"reqtype\"\r\n\r\nfileupload\r\n" +
            "--\(request.boundary)\r\nContent-Disposition: form-data; name=\"time\"\r\n\r\n12h\r\n" +
            "--\(request.boundary)\r\nContent-Disposition: form-data; name=\"fileToUpload\"; filename=\"\(filename)\"\r\n" +
            "Content-Type: \(kind.contentType)\r\n\r\n").utf8)
        let suffix = Data("\r\n--\(request.boundary)--\r\n".utf8)
        precondition(request.length == Int64(data.count))
        precondition(data == prefix + payload + suffix)
    }

    for response in ["http://litter.catbox.moe/example.ipa", "https://litter.catbox.moe.other.test/example.ipa",
                     "https://me@litter.catbox.moe/example.ipa", "https://litter.catbox.moe/example.ipa?token=1",
                     "https://litter.catbox.moe/", "<html>A landing page</html>"] {
        expectFailure { _ = try litterbox.downloadURL(from: Data(response.utf8)) }
    }
    expectFailure { _ = try HostedIPAMultipart.write(file: signed.file, kind: .ipa, provider: litterbox, choices: ["retention": "96h"]) }

    try manager.createSymbolicLink(atPath: app.appendingPathComponent("Outside").path, withDestinationPath: "../outside")
    do {
        _ = try await HostedIPAArchive.prepare(app: app, forInstallation: false)
        fatalError("Accepted a symlink outside the package")
    } catch HostedIPAError.unsafeSymlink {}
    print("Hosted IPA archive, manifest, provider catalog, UA and multipart checks passed")
}

private func checkFile2Me(catalog: UploadProviderCatalog, catalogData: Data) throws {
    guard let provider = catalog.providers.first(where: \.usesFile2Me) else {
        fatalError("Missing file2.me provider")
    }
    precondition(provider.fileLimitBytes == 500_000_000 && provider.id == "file2-me")
    precondition(!catalog.providers.contains(where: { $0.id == "okfile" }))
    let options = try provider.fields(choices: ["retention": "7d"])
    precondition(options == ["expiry": "7d"])
    expectFailure { _ = try provider.fields(choices: ["retention": "30d"]) }

    let raw = try File2Me.rawURL(shareID: "test_A-b1")
    precondition(raw.absoluteString == "https://file2.me/raw/test_A-b1" && provider.allowsDownload(raw))
    expectFailure { _ = try File2Me.rawURL(shareID: "../share") }
    expectFailure { _ = try File2Me.rawURL(shareID: "test\n") }
    for invalid in ["https://file2.me:8443/raw/test", "https://file2.me/raw/test?redirect=1",
                    "https://file2.me.evil.test/raw/test", "https://file2.me/api/test"] {
        precondition(!provider.allowsDownload(URL(string: invalid)!))
    }
    let storage = "https://0123456789abcdef0123456789abcdef.r2.cloudflarestorage.com/bucket/key?X-Amz-Signature=fixture"
    let target = try File2Me.storageRedirect(from: raw, status: 307, location: storage)
    precondition(target.absoluteString == storage && !provider.allowsDownload(target))
    expectFailure { _ = try File2Me.storageRedirect(from: raw, status: 302, location: storage) }
    for invalid in ["http://" + storage.dropFirst(8), "https://localhost/file?X-Amz-Signature=fixture",
                    storage.replacingOccurrences(of: ".com/", with: ".com.evil.test/"),
                    storage.replacingOccurrences(of: ".com/", with: ".com:8443/"),
                    String(storage.split(separator: "?")[0])] {
        expectFailure { _ = try File2Me.storageRedirect(from: raw, status: 307, location: invalid) }
    }
    let handoff = InstallationTransport.installationURL(manifest: raw)
    let query = URLComponents(url: handoff, resolvingAgainstBaseURL: false)?.queryItems
    precondition(query?.first(where: { $0.name == "url" })?.value == raw.absoluteString)

    var old = try JSONSerialization.jsonObject(with: catalogData) as! [String: Any]
    let file2Me = old.removeValue(forKey: "file2Me") as! [String: Any]
    let legacy = try UploadProviderCatalog.decode(JSONSerialization.data(withJSONObject: old))
    precondition(!legacy.providers.contains(where: \.usesFile2Me))
    var providers = old["providers"] as! [[String: Any]]
    providers.append(file2Me)
    old["providers"] = providers
    expectFailure { _ = try UploadProviderCatalog.decode(JSONSerialization.data(withJSONObject: old)) }
}
