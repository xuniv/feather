#!/usr/bin/env python3
"""Synthetic, offline integration checks for per-bundle signing and resource seals."""
import base64
import hashlib
import importlib.util
import os
from pathlib import Path
import plistlib
import struct
import subprocess
import sys
import tempfile


def command(*args):
    try:
        subprocess.run(args, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    except subprocess.CalledProcessError as error:
        print(error.stderr.decode(errors='replace'), file=sys.stderr)
        raise


def macho():
    # Inert ARM64 Mach-O bytes with enough space for load commands and signatures.
    # They are parsed/signed only, never executed on the host or a device.
    text = struct.pack('<II16sQQQQIIII', 0x19, 152, b'__TEXT', 0x100000000, 8192, 0, 8192, 7, 5, 1, 0)
    text += struct.pack('<16s16sQQIIIIIIII', b'__text', b'__TEXT', 0x100001000, 4, 4096, 2, 0, 0, 0x80000400, 0, 0, 0)
    link = struct.pack('<II16sQQQQIIII', 0x19, 72, b'__LINKEDIT', 0x100002000, 65536, 8192, 65536, 7, 1, 0, 0)
    signature = struct.pack('<IIII', 0x1d, 16, 8192, 65536)
    header = struct.pack('<IIIIIIII', 0xfeedfacf, 0x0100000c, 0, 2, 3, len(text + link + signature), 0, 0)
    data = bytearray(8192 + 65536)
    data[:len(header + text + link + signature)] = header + text + link + signature
    data[4096:4100] = b'\xc0\x03\x5f\xd6'
    data[8192:8204] = struct.pack('>III', 0xfade0cc0, 65536, 0)
    return data


def slots(binary):
    data = binary.read_bytes()
    count = struct.unpack_from('<I', data, 16)[0]
    offset = 32
    for _ in range(count):
        cmd, length = struct.unpack_from('<II', data, offset)
        if cmd == 0x1d:
            base = struct.unpack_from('<I', data, offset + 8)[0]
            magic, size, entries = struct.unpack_from('>III', data, base)
            assert magic == 0xfade0cc0
            result = {}
            for i in range(entries):
                kind, position = struct.unpack_from('>II', data, base + 12 + i * 8)
                blob_magic, length = struct.unpack_from('>II', data, base + position)
                result[kind] = data[base + position:base + position + length]
            return data, result
        offset += length
    raise AssertionError('Missing code signature')


def check(bundle, identifier, profile, remove, verify_cms=True):
    data, blobs = slots(bundle / 'Executable')
    entitlements = plistlib.loads(blobs[5][8:])
    assert entitlements['application-identifier'] == 'LEGACY1234.' + identifier
    assert entitlements['com.apple.developer.team-identifier'] == 'NEWTEAM123'
    assert entitlements['keychain-access-groups'] == ['LEGACY1234.' + identifier]
    assert 7 in blobs, 'Missing DER entitlements'
    embedded = bundle / 'embedded.mobileprovision'
    assert embedded.exists() != remove
    if not remove:
        assert embedded.read_bytes() == profile.read_bytes()
    resources = bundle / '_CodeSignature/CodeResources'
    seal = plistlib.loads(resources.read_bytes())
    for relative, hashes in seal['files2'].items():
        if isinstance(hashes, dict) and 'hash2' in hashes:
            assert hashlib.sha256((bundle / relative).read_bytes()).digest() == hashes['hash2'], relative
    for blob in blobs.values():
        magic = struct.unpack_from('>I', blob)[0]
        if magic != 0xfade0c02:
            continue
        _, _, version, flags, hash_offset, id_offset, special, pages, code_limit = struct.unpack_from('>9I', blob)
        hash_size, hash_type, platform, page_log = struct.unpack_from('4B', blob, 36)
        digest = hashlib.sha256 if hash_type == 2 else hashlib.sha1
        for page in range(pages):
            expected = digest(data[page * (1 << page_log):min((page + 1) * (1 << page_log), code_limit)]).digest()
            assert blob[hash_offset + page * hash_size:hash_offset + (page + 1) * hash_size] == expected
        for slot, contents in [(1, (bundle / 'Info.plist').read_bytes()), (3, resources.read_bytes()), (5, blobs[5]), (7, blobs[7])]:
            assert slot <= special
            assert blob[hash_offset - slot * hash_size:hash_offset - (slot - 1) * hash_size] == digest(contents).digest(), (bundle.name, slot)

    if verify_cms:
        # Verify the actual CMS signature independently of the page/slot hashes.
        with tempfile.TemporaryDirectory() as temporary:
            cms = Path(temporary) / 'signature.cms'
            content = Path(temporary) / 'directory.bin'
            cms.write_bytes(blobs[0x10000][8:])
            content.write_bytes(blobs[0])
            command('openssl', 'cms', '-verify', '-binary', '-inform', 'DER', '-in', str(cms), '-content', str(content), '-noverify', '-out', os.devnull)


def run(driver):
    with tempfile.TemporaryDirectory(prefix='signing-fixture-') as temporary:
        root = Path(temporary)
        command('openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', str(root / 'ca.key'), '-out', str(root / 'ca.crt'), '-days', '2', '-subj', '/CN=Synthetic Signing CA')
        command('openssl', 'req', '-new', '-newkey', 'rsa:2048', '-nodes', '-keyout', str(root / 'leaf.key'), '-out', str(root / 'leaf.csr'), '-subj', '/CN=Synthetic Signing Leaf/OU=NEWTEAM123')
        command('openssl', 'x509', '-req', '-in', str(root / 'leaf.csr'), '-CA', str(root / 'ca.crt'), '-CAkey', str(root / 'ca.key'), '-CAcreateserial', '-out', str(root / 'leaf.crt'), '-days', '2')
        command('openssl', 'x509', '-in', str(root / 'leaf.crt'), '-outform', 'DER', '-out', str(root / 'leaf.der'))
        command('openssl', 'pkcs12', '-export', '-inkey', str(root / 'leaf.key'), '-in', str(root / 'leaf.crt'), '-certfile', str(root / 'ca.crt'), '-passout', 'pass:fixture', '-out', str(root / 'identity.p12'))
        template = macho()
        if sys.platform == 'darwin':
            source = root / 'fixture.c'
            source.write_text('int main(void) { return 0; }\n')
            executable = root / 'fixture'
            command('xcrun', '--sdk', 'iphoneos', 'clang', '-arch', 'arm64', '-miphoneos-version-min=16.0', '-Wl,-headerpad,0x4000', '-g0', str(source), '-o', str(executable))
            template = executable.read_bytes()
        entries = [('main', root / 'Test.app', 'com.example.app'),
                   ('widget', root / 'Test.app/PlugIns/Widget.appex', 'com.example.app.widget'),
                   ('companion', root / 'Test.app/Nested/Companion.app', 'com.example.app.companion')]
        for name, bundle, identifier in entries:
            bundle.mkdir(parents=True)
            (bundle / 'Executable').write_bytes(template)
            (bundle / 'Executable').chmod(0o755)
            (bundle / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': identifier, 'CFBundleExecutable': 'Executable',
                'CFBundleVersion': '1', 'CFBundleShortVersionString': '2.9.1', 'CFBundleName': name,
                'CFBundleSupportedPlatforms': ['iPhoneOS']}))
            (bundle / 'resource.txt').write_text(name)
            entitlements = {'application-identifier': 'LEGACY1234.' + identifier, 'com.apple.developer.team-identifier': 'NEWTEAM123', 'keychain-access-groups': ['LEGACY1234.' + identifier]}
            (root / (name + '.plist')).write_bytes(plistlib.dumps(entitlements))
            profile = {'TeamIdentifier': ['NEWTEAM123'], 'DeveloperCertificates': [(root / 'leaf.der').read_bytes()], 'Entitlements': dict(entitlements, **{'application-identifier': 'LEGACY1234.*'})}
            (root / (name + '-profile.plist')).write_bytes(plistlib.dumps(profile))
            command('openssl', 'cms', '-sign', '-binary', '-nodetach', '-in', str(root / (name + '-profile.plist')), '-signer', str(root / 'leaf.crt'), '-inkey', str(root / 'leaf.key'), '-outform', 'DER', '-out', str(root / (name + '.mobileprovision')))
        for mode in ('keep', 'remove'):
            command(str(driver), str(root), mode)
            for name, bundle, identifier in entries:
                check(bundle, identifier, root / (name + '.mobileprovision'), mode == 'remove')
        # No certificate or profile paths are passed to the ad-hoc signing assets.
        command(str(driver), str(root), 'adhoc')
        for name, bundle, identifier in reversed(entries):
            check(bundle, identifier, root / (name + '.mobileprovision'), True, verify_cms=False)
            if sys.platform == 'darwin':
                # Synthetic certificates cannot meet the production Apple anchor;
                # verify ad-hoc structure using the system verifier instead.
                command('/usr/bin/codesign', '--verify', '--strict', '--verbose=2', str(bundle))
        if sys.platform == 'darwin':
            # Exercise actual signature stripping on the compiler-built app,
            # extension and nested app, while preserving the input fixture.
            script = Path(__file__).resolve().parents[2] / 'scripts/unsigned_ipa.py'
            spec = importlib.util.spec_from_file_location('unsigned_ipa', script)
            packaging = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(packaging)
            result = packaging.prepare(root / 'Test.app', root / 'unsigned.ipa', '2.9.1')
            assert result['unsigned_macho_files'] == 3
            assert 5 in slots(root / 'Test.app/Executable')[1]
        # A valid p12 must not sign using a profile which omits its certificate.
        profile['DeveloperCertificates'] = []
        (root / 'unauthorized.plist').write_bytes(plistlib.dumps(profile))
        command('openssl', 'cms', '-sign', '-binary', '-nodetach', '-in', str(root / 'unauthorized.plist'), '-signer', str(root / 'leaf.crt'), '-inkey', str(root / 'leaf.key'), '-outform', 'DER', '-out', str(root / 'main.mobileprovision'))
        assert subprocess.run([str(driver), str(root), 'keep'], stdout=subprocess.DEVNULL).returncode != 0
    print('Per-bundle identities, DER entitlements, page hashes, nested seals, provisioning removal and certificate authorization passed')


if __name__ == '__main__':
    run(Path(sys.argv[1]).resolve())
