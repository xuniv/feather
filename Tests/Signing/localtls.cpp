#include "localtls.h"
#include <fstream>
#include <iostream>
#include <iterator>

int main(int argc, char** argv) {
    if (argc == 3) {
        std::ifstream file(argv[2]);
        std::string legacyPEM((std::istreambuf_iterator<char>(file)), std::istreambuf_iterator<char>());
        if (!LocalTLSCertificateSupportsHost(legacyPEM, "localhost") ||
            !LocalTLSCertificateSupportsHost(legacyPEM, "127.0.0.1") ||
            LocalTLSCertificateSupportsHost(legacyPEM, "feather.localhost")) return 1;
        std::cout << "Legacy localhost identity remains compatible\n";
        return 0;
    }
    if (argc != 2) return 2;
    LocalTLSIdentity first, second;
    if (!GenerateLocalTLSIdentity(first) || !GenerateLocalTLSIdentity(second)) return 1;
    if (first.privateKeyPEM == second.privateKeyPEM || first.authorityDER == second.authorityDER) return 1;
    for (const auto* host : {"feather.localhost", "localhost", "127.0.0.1", "::1"}) {
        if (!LocalTLSCertificateSupportsHost(first.certificatePEM, host)) return 1;
    }
    for (const auto* host : {"example.org", "other.localhost", "", "127.0.0.2"}) {
        if (LocalTLSCertificateSupportsHost(first.certificatePEM, host)) return 1;
    }
    if (LocalTLSCertificateSupportsHost("invalid PEM", "localhost")) return 1;
    const std::string directory = argv[1];
    std::ofstream(directory + "/server.crt") << first.certificatePEM;
    std::ofstream(directory + "/server.pem") << first.privateKeyPEM;
    std::ofstream(directory + "/authority.der", std::ios::binary) << first.authorityDER;
    std::cout << "Generated distinct local identities\n";
}
