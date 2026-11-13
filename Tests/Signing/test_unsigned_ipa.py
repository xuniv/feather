import importlib.util
from pathlib import Path
import plistlib
import struct
import tempfile
import unittest
import zipfile

module_path = Path(__file__).resolve().parents[2] / 'scripts/unsigned_ipa.py'
spec = importlib.util.spec_from_file_location('unsigned_ipa', module_path)
packaging = importlib.util.module_from_spec(spec)
spec.loader.exec_module(packaging)


class UnsignedIPATests(unittest.TestCase):
    def fixture(self, root, extra=None, signature=False):
        output = Path(root) / 'test.ipa'
        info = {'CFBundleIdentifier': 'com.example.fixture', 'CFBundleVersion': '2.9.1',
                'CFBundleShortVersionString': '2.9.1', 'CFBundleExecutable': 'Executable',
                'CFBundleSupportedPlatforms': ['iPhoneOS']}
        binary = struct.pack('<8I', 0xfeedfacf, 0x0100000c, 0, 2, 1 if signature else 0, 16 if signature else 0, 0, 0)
        if signature:
            binary += struct.pack('<4I', 0x1d, 16, 48, 12) + struct.pack('>3I', 0xfade0cc0, 12, 0)
        with zipfile.ZipFile(output, 'w') as archive:
            archive.writestr('Payload/Test.app/Info.plist', plistlib.dumps(info))
            archive.writestr('Payload/Test.app/Executable', binary)
            for name, data in (extra or {}).items():
                archive.writestr(name, data)
        return output

    def test_unsigned_archive_and_version(self):
        with tempfile.TemporaryDirectory() as directory:
            output = self.fixture(directory)
            self.assertEqual(packaging.verify(output, '2.9.1')['unsigned_macho_files'], 1)
            with self.assertRaises(ValueError):
                packaging.verify(output, '2.9.0')

    def test_reject_signature_profile_credentials_and_unsafe_paths(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(ValueError):
                packaging.verify(self.fixture(directory, signature=True))
            for path in ['Payload/Test.app/embedded.mobileprovision', 'Payload/Test.app/server.pem',
                         'Payload/Test.app/_CodeSignature/CodeResources', '../outside', 'build.log']:
                with self.subTest(path=path), self.assertRaises(ValueError):
                    packaging.verify(self.fixture(directory, {path: b'fixture'}))

    def test_prepare_preserves_executable_modes_without_metadata(self):
        with tempfile.TemporaryDirectory() as directory:
            source = self.fixture(directory)
            with zipfile.ZipFile(source) as archive:
                archive.extractall(Path(directory) / 'input')
            app = Path(directory) / 'input/Payload/Test.app'
            (app / 'Executable').chmod(0o755)
            output = Path(directory) / 'unsigned.ipa'
            packaging.prepare(app, output, '2.9.1')
            with zipfile.ZipFile(output) as archive:
                entry = archive.getinfo('Payload/Test.app/Executable')
                self.assertEqual((entry.external_attr >> 16) & 0o777, 0o755)
                self.assertEqual(entry.date_time, (1980, 1, 1, 0, 0, 0))
                self.assertFalse(entry.extra)


if __name__ == '__main__':
    unittest.main()
