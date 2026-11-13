#!/usr/bin/env python3
"""Package and verify a credential-free IPA without launching any app code."""
import argparse
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import shutil
import stat
import struct
import subprocess
import tempfile
import zipfile


MAGICS = {b'\xfe\xed\xfa\xce', b'\xce\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xcf\xfa\xed\xfe',
          b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca', b'\xca\xfe\xba\xbf', b'\xbf\xba\xfe\xca'}
FORBIDDEN = {'.p12', '.pfx', '.pem', '.key', '.crt', '.mobileprovision', '.provisionprofile', '.mobileconfig'}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def architectures(data):
    if data[:4] not in MAGICS:
        return []
    magic = data[:4]
    if magic in {b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca', b'\xca\xfe\xba\xbf', b'\xbf\xba\xfe\xca'}:
        little = magic in {b'\xbe\xba\xfe\xca', b'\xbf\xba\xfe\xca'}
        wide = magic in {b'\xca\xfe\xba\xbf', b'\xbf\xba\xfe\xca'}
        order = '<' if little else '>'
        require(len(data) >= 8, 'Truncated fat header')
        count = struct.unpack_from(order + 'I', data, 4)[0]
        stride = 32 if wide else 20
        require(0 < count <= 64 and 8 + count * stride <= len(data), 'Invalid fat architecture table')
        result = []
        for index in range(count):
            base = 8 + index * stride
            offset, size = struct.unpack_from(order + ('QQ' if wide else 'II'), data, base + 8)
            require(offset >= 8 + count * stride and size >= 28 and offset + size <= len(data), 'Invalid fat slice')
            result.extend(architectures(data[offset:offset + size]))
        require(len(result) >= count, 'Invalid inner Mach-O slice')
        return result
    order = '<' if magic in {b'\xce\xfa\xed\xfe', b'\xcf\xfa\xed\xfe'} else '>'
    header = 32 if magic in {b'\xfe\xed\xfa\xcf', b'\xcf\xfa\xed\xfe'} else 28
    require(len(data) >= header, 'Truncated Mach-O header')
    _, cpu, _, _, count, size, _ = struct.unpack_from(order + '7I', data)
    require(header + size <= len(data) and count <= size // 8, 'Invalid Mach-O commands')
    offset, signature, encrypted = header, False, False
    for _ in range(count):
        require(offset + 8 <= header + size, 'Truncated load command')
        command, length = struct.unpack_from(order + 'II', data, offset)
        require(length >= 8 and offset + length <= header + size, 'Invalid load command length')
        signature |= command == 0x1d
        if command in {0x21, 0x2c}:
            require(length >= (24 if command == 0x2c else 20), 'Truncated encryption command')
            encrypted |= struct.unpack_from(order + 'I', data, offset + 16)[0] != 0
        offset += length
    return [{'cpu': cpu, 'signature': signature, 'encrypted': encrypted}]


def verify(ipa, version=None):
    with zipfile.ZipFile(ipa) as archive:
        entries = archive.infolist()
        names = [entry.filename for entry in entries]
        require(len(names) == len(set(names)), 'Duplicate archive paths')
        require(sum(entry.file_size for entry in entries) < 1024 ** 3, 'Unexpected archive size')
        apps = set()
        for entry in entries:
            path = PurePosixPath(entry.filename)
            require(not path.is_absolute() and '..' not in path.parts and '\\' not in entry.filename, 'Unsafe archive path')
            require(path.parts and path.parts[0] == 'Payload', 'Unexpected top-level content')
            if len(path.parts) > 1:
                require(path.parts[1].endswith('.app'), 'Unexpected Payload content')
                apps.add(path.parts[1])
            require('_CodeSignature' not in path.parts and path.suffix.lower() not in FORBIDDEN, 'Signing material remains in IPA')
            require(path.name not in {'.DS_Store', 'embedded.provisionprofile'}, 'Unwanted package metadata')
            if stat.S_ISLNK(entry.external_attr >> 16):
                target = archive.read(entry).decode('utf-8')
                require(not target.startswith('/'), 'Absolute symlink in IPA')
                normalized = os.path.normpath(str(path.parent / target))
                require(len(path.parts) > 1 and normalized.startswith('Payload/' + path.parts[1] + '/'), 'Escaping symlink in IPA')
        require(len(apps) == 1, 'Expected exactly one root app')
        root = 'Payload/' + next(iter(apps)) + '/'
        info = plistlib.loads(archive.read(root + 'Info.plist'))
        require(info.get('CFBundleSupportedPlatforms') == ['iPhoneOS'], 'Not an iPhoneOS app')
        require(info.get('CFBundleIdentifier') and info.get('CFBundleVersion'), 'Missing app identity')
        if version:
            require(info.get('CFBundleShortVersionString') == version, 'Release version mismatch')
        executable = info.get('CFBundleExecutable', '')
        require(executable and '/' not in executable and executable != '..', 'Invalid executable name')
        main = architectures(archive.read(root + executable))
        require(any(item['cpu'] == 0x0100000c for item in main), 'Missing arm64 executable')
        binaries = 0
        for entry in entries:
            if entry.is_dir() or stat.S_ISLNK(entry.external_attr >> 16):
                continue
            with archive.open(entry) as stream:
                magic = stream.read(4)
            if magic not in MAGICS:
                continue
            slices = architectures(archive.read(entry))
            require(slices and not any(item['signature'] for item in slices), 'Code signature remains: ' + entry.filename)
            require(not any(item['encrypted'] for item in slices), 'Encrypted binary: ' + entry.filename)
            binaries += 1
        require(archive.testzip() is None, 'Corrupt IPA archive')
        return {'identifier': info['CFBundleIdentifier'], 'version': info['CFBundleShortVersionString'],
                'build': info['CFBundleVersion'], 'unsigned_macho_files': binaries}


def prepare(app, output, version=None):
    app, output = Path(app).resolve(), Path(output).resolve()
    require(app.is_dir() and app.suffix == '.app', 'Expected a built app directory')
    require(not output.is_relative_to(app), 'Output must be outside the app')
    with tempfile.TemporaryDirectory(prefix='unsigned-ipa-') as temporary:
        staging = Path(temporary)
        copied = staging / 'Payload' / app.name
        shutil.copytree(app, copied, symlinks=True)
        # Remove resource seals and profiles before removing linker ad-hoc signatures.
        for path in sorted(copied.rglob('*'), key=lambda item: len(item.parts), reverse=True):
            if path.name == '_CodeSignature':
                if path.is_symlink():
                    path.unlink()
                else:
                    shutil.rmtree(path)
            elif path.suffix.lower() in {'.mobileprovision', '.provisionprofile'}:
                path.unlink()
            elif path.name == '.DS_Store':
                path.unlink()
        for path in copied.rglob('*'):
            if path.is_symlink() or not path.is_file():
                continue
            with path.open('rb') as stream:
                magic = stream.read(4)
            if magic in MAGICS and any(item['signature'] for item in architectures(path.read_bytes())):
                subprocess.run(['/usr/bin/codesign', '--remove-signature', str(path)], check=True)
        output.parent.mkdir(parents=True, exist_ok=True)
        with zipfile.ZipFile(output, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
            for path in sorted(staging.rglob('*')):
                relative = path.relative_to(staging).as_posix()
                mode = path.lstat().st_mode
                directory = stat.S_ISDIR(mode)
                item = zipfile.ZipInfo(relative + ('/' if directory else ''))
                item.create_system = 3
                item.external_attr = mode << 16
                item.compress_type = zipfile.ZIP_DEFLATED
                # Fixed ZIP timestamps and no extra fields avoid host/session metadata.
                data = os.readlink(path).encode('utf-8') if path.is_symlink() else b'' if directory else path.read_bytes()
                archive.writestr(item, data)
        return verify(output, version)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['prepare', 'verify'])
    parser.add_argument('source')
    parser.add_argument('output', nargs='?')
    parser.add_argument('--version')
    args = parser.parse_args()
    if args.action == 'prepare':
        require(args.output, 'An output IPA path is required')
        result = prepare(args.source, args.output, args.version)
    else:
        result = verify(args.source, args.version)
    print(json.dumps(result, sort_keys=True))
