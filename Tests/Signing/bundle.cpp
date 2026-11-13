#include "bundle.h"
#include <memory>
#include <string>
#include <vector>

// The fixture contains no Apple identity and no executable test is launched.
int main(int argc, char** argv) {
    if (argc != 3) return 2;
    std::string root = argv[1];
    std::vector<std::unique_ptr<ZSignAsset>> assets;
    ZBundle bundle;
    for (const std::string path : {"/", "PlugIns/Widget.appex", "Nested/Companion.app"}) {
        auto asset = std::unique_ptr<ZSignAsset>(new ZSignAsset());
        const std::string name = path == "/" ? "main" : path == "PlugIns/Widget.appex" ? "widget" : "companion";
        bool adhoc = std::string(argv[2]) == "adhoc";
        if (!asset->Init("", adhoc ? "" : root + "/identity.p12", adhoc ? "" : root + "/" + name + ".mobileprovision",
            root + "/" + name + ".plist", adhoc ? "" : "fixture", adhoc, false, false)) return 1;
        bundle.m_signingAssetsByPath[path] = asset.get();
        assets.push_back(std::move(asset));
    }
    std::vector<std::string> empty;
    return bundle.SignFolder(assets[0].get(), root + "/Test.app", "", "", "", empty, empty,
        true, false, false, std::string(argv[2]) == "remove") ? 0 : 1;
}
