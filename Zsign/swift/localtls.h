#pragma once
#include <string>

struct LocalTLSIdentity {
    std::string certificatePEM;
    std::string privateKeyPEM;
    std::string authorityDER;
};

// The CA key stays in memory and is discarded after issuing the loopback leaf.
bool GenerateLocalTLSIdentity(LocalTLSIdentity& output);
bool LocalTLSCertificateSupportsHost(const std::string& certificatePEM, const std::string& host);
