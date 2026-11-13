#include "localtls.h"
#include <fstream>
#include <iostream>

int main(int argc, char** argv) {
    if (argc != 2) return 2;
    LocalTLSIdentity first, second;
    if (!GenerateLocalTLSIdentity(first) || !GenerateLocalTLSIdentity(second)) return 1;
    if (first.privateKeyPEM == second.privateKeyPEM || first.authorityDER == second.authorityDER) return 1;
    const std::string directory = argv[1];
    std::ofstream(directory + "/server.crt") << first.certificatePEM;
    std::ofstream(directory + "/server.pem") << first.privateKeyPEM;
    std::ofstream(directory + "/authority.der", std::ios::binary) << first.authorityDER;
    std::cout << "Generated distinct local identities\n";
}
