#include "localtls.h"
#include <openssl/evp.h>
#include <openssl/ec.h>
#include <openssl/x509.h>
#include <openssl/x509v3.h>
#include <openssl/pem.h>
#include <openssl/rand.h>
#include <memory>

namespace {
using Key = std::unique_ptr<EVP_PKEY, decltype(&EVP_PKEY_free)>;
using Cert = std::unique_ptr<X509, decltype(&X509_free)>;
using Bio = std::unique_ptr<BIO, decltype(&BIO_free)>;

Key key() {
    EVP_PKEY* value = nullptr;
    std::unique_ptr<EVP_PKEY_CTX, decltype(&EVP_PKEY_CTX_free)> context(EVP_PKEY_CTX_new_id(EVP_PKEY_EC, nullptr), EVP_PKEY_CTX_free);
    if (!context || EVP_PKEY_keygen_init(context.get()) <= 0 ||
        EVP_PKEY_CTX_set_ec_paramgen_curve_nid(context.get(), NID_X9_62_prime256v1) <= 0 ||
        EVP_PKEY_keygen(context.get(), &value) <= 0) return Key(nullptr, EVP_PKEY_free);
    return Key(value, EVP_PKEY_free);
}

bool extension(X509* cert, X509* issuer, int nid, const char* value) {
    X509V3_CTX context;
    X509V3_set_ctx(&context, issuer, cert, nullptr, nullptr, 0);
    std::unique_ptr<X509_EXTENSION, decltype(&X509_EXTENSION_free)> ext(
        X509V3_EXT_conf_nid(nullptr, &context, nid, const_cast<char*>(value)), X509_EXTENSION_free);
    return ext && X509_add_ext(cert, ext.get(), -1) == 1;
}

Cert certificate(EVP_PKEY* key, const char* name, long days) {
    Cert cert(X509_new(), X509_free);
    unsigned char serial[20];
    if (!cert || RAND_bytes(serial, sizeof(serial)) != 1) return Cert(nullptr, X509_free);
    serial[0] &= 0x7f;
    serial[0] |= 1;
    std::unique_ptr<BIGNUM, decltype(&BN_free)> number(BN_bin2bn(serial, sizeof(serial), nullptr), BN_free);
    if (!number || !BN_to_ASN1_INTEGER(number.get(), X509_get_serialNumber(cert.get())) ||
        X509_set_version(cert.get(), 2) != 1 || X509_set_pubkey(cert.get(), key) != 1 ||
        !X509_gmtime_adj(X509_getm_notBefore(cert.get()), -300) ||
        !X509_gmtime_adj(X509_getm_notAfter(cert.get()), days * 86400L) ||
        X509_NAME_add_entry_by_txt(X509_get_subject_name(cert.get()), "CN", MBSTRING_ASC,
            reinterpret_cast<const unsigned char*>(name), -1, -1, 0) != 1) return Cert(nullptr, X509_free);
    return cert;
}

std::string bytes(BIO* bio) {
    char* data = nullptr;
    long count = BIO_get_mem_data(bio, &data);
    return count > 0 ? std::string(data, count) : std::string();
}
}

bool GenerateLocalTLSIdentity(LocalTLSIdentity& output) {
    auto authorityKey = key();
    auto serverKey = key();
    if (!authorityKey || !serverKey) return false;
    auto authority = certificate(authorityKey.get(), "Feather Local Installation CA", 3650);
    auto server = certificate(serverKey.get(), "localhost", 397);
    if (!authority || !server ||
        X509_set_issuer_name(authority.get(), X509_get_subject_name(authority.get())) != 1 ||
        !extension(authority.get(), authority.get(), NID_basic_constraints, "critical,CA:TRUE,pathlen:0") ||
        !extension(authority.get(), authority.get(), NID_key_usage, "critical,keyCertSign,cRLSign") ||
        !extension(authority.get(), authority.get(), NID_subject_key_identifier, "hash") ||
        X509_sign(authority.get(), authorityKey.get(), EVP_sha256()) <= 0 ||
        X509_set_issuer_name(server.get(), X509_get_subject_name(authority.get())) != 1 ||
        !extension(server.get(), authority.get(), NID_basic_constraints, "critical,CA:FALSE") ||
        !extension(server.get(), authority.get(), NID_key_usage, "critical,digitalSignature") ||
        !extension(server.get(), authority.get(), NID_ext_key_usage, "serverAuth") ||
        !extension(server.get(), authority.get(), NID_subject_alt_name, "DNS:localhost,IP:127.0.0.1") ||
        !extension(server.get(), authority.get(), NID_subject_key_identifier, "hash") ||
        !extension(server.get(), authority.get(), NID_authority_key_identifier, "keyid:always") ||
        X509_sign(server.get(), authorityKey.get(), EVP_sha256()) <= 0) return false;

    Bio certBIO(BIO_new(BIO_s_mem()), BIO_free);
    Bio keyBIO(BIO_new(BIO_s_mem()), BIO_free);
    if (!certBIO || !keyBIO || PEM_write_bio_X509(certBIO.get(), server.get()) != 1 ||
        PEM_write_bio_X509(certBIO.get(), authority.get()) != 1 ||
        PEM_write_bio_PrivateKey(keyBIO.get(), serverKey.get(), nullptr, nullptr, 0, nullptr, nullptr) != 1) return false;
    unsigned char* der = nullptr;
    int count = i2d_X509(authority.get(), &der);
    if (count <= 0) return false;
    output.authorityDER.assign(reinterpret_cast<char*>(der), count);
    OPENSSL_free(der);
    output.certificatePEM = bytes(certBIO.get());
    output.privateKeyPEM = bytes(keyBIO.get());
    return !output.certificatePEM.empty() && !output.privateKeyPEM.empty();
}
