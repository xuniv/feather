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
        if (!asset->Init("", root + "/identity.p12", root + "/" + name + ".mobileprovision",
            root + "/" + name + ".plist", "fixture", false, false, false)) return 1;
        if (std::string(argv[2]) == "adhoc") {
            asset->m_bAdhoc = true;
            asset->m_strSubjectCN.clear();
            asset->m_strTeamId.clear();
        }
        bundle.m_signingAssetsByPath[path] = asset.get();
        assets.push_back(std::move(asset));
    }
    std::vector<std::string> empty;
    return bundle.SignFolder(assets[0].get(), root + "/Test.app", "", "", "", empty, empty,
        true, false, false, std::string(argv[2]) == "remove") ? 0 : 1;
}
