import copy
import hashlib
import io
import json
import struct
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import update


def MakeArchive(arch, machine):
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w:gz") as archive:
        for filename in (
            "mesl-cli",
            "mihomo",
            "geoip.metadb",
            "README.md",
            "mesl-cli.service",
        ):
            data = bytearray(64)
            data[:6] = b"\x7fELF\x02\x01"
            struct.pack_into("<H", data, 18, machine)
            member = tarfile.TarInfo(f"mesl-linux-{arch}/{filename}")
            member.size = len(data)
            archive.addfile(member, io.BytesIO(data))
    return buffer.getvalue()


class UpdateTests(unittest.TestCase):
    def setUp(self):
        self.current = json.loads(
            (Path(__file__).resolve().parents[1] / "release.json").read_text()
        )
        self.nextVersion = ".".join(
            [
                *self.current["version"].split(".")[:2],
                str(int(self.current["version"].split(".")[2]) + 1),
            ]
        )
        self.archives = {
            arch: MakeArchive(arch, machine)
            for arch, machine in update.architectures.values()
        }
        self.manifest = {
            "linux": {"version": self.nextVersion, "urls": {}, "files": {}}
        }
        for arch, archiveData in self.archives.items():
            filename = f"mesl-linux-{arch}.tar.gz"
            self.manifest["linux"]["urls"][arch] = f"https://example.com/{filename}"
            self.manifest["linux"]["files"][filename] = {
                "sha256": hashlib.sha256(archiveData).hexdigest(),
                "size": len(archiveData),
            }

    def Fetch(self, url, version):
        if url in update.manifestUrls:
            return json.dumps(self.manifest).encode()
        for arch, archiveData in self.archives.items():
            if url == self.manifest["linux"]["urls"][arch]:
                return archiveData
        raise AssertionError("Unexpected URL")

    def test_newer_release_and_numeric_order(self):
        self.assertGreater(update.ParseVersion("2.0.10"), update.ParseVersion("2.0.9"))
        candidate = update.Discover(self.current, self.Fetch)
        self.assertEqual(candidate["version"], self.nextVersion)
        self.assertEqual(set(candidate["sources"]), set(update.architectures))

    def test_unchanged_and_repack(self):
        self.manifest["linux"]["version"] = self.current["version"]
        for system, (arch, _) in update.architectures.items():
            import base64

            source = self.current["sources"][system]
            self.manifest["linux"]["files"][f"mesl-linux-{arch}.tar.gz"] = {
                "sha256": base64.b64decode(source["hash"].split("-", 1)[1]).hex(),
                "size": source["size"],
            }
        self.assertIsNone(update.Discover(self.current, self.Fetch))
        self.manifest["linux"]["files"]["mesl-linux-amd64.tar.gz"]["sha256"] = "0" * 64
        with self.assertRaisesRegex(ValueError, "Same-version"):
            update.Discover(self.current, self.Fetch)

    def test_older_release(self):
        self.manifest["linux"] = {"version": "0.0.0"}
        self.assertIsNone(update.Discover(self.current, self.Fetch))

    def test_missing_architecture_hash_size_and_machine(self):
        for mutation in ("missing", "hash", "size", "machine"):
            with self.subTest(mutation=mutation):
                original = copy.deepcopy(self.manifest)
                if mutation == "missing":
                    del self.manifest["linux"]["urls"]["arm64"]
                elif mutation == "hash":
                    self.manifest["linux"]["files"]["mesl-linux-amd64.tar.gz"][
                        "sha256"
                    ] = "0" * 64
                elif mutation == "size":
                    self.manifest["linux"]["files"]["mesl-linux-amd64.tar.gz"][
                        "size"
                    ] += 1
                else:
                    with self.assertRaisesRegex(ValueError, "ELF"):
                        update.InspectArchive(self.archives["amd64"], "amd64", 183)
                    continue
                with self.assertRaises((ValueError, KeyError)):
                    update.Discover(self.current, self.Fetch)
                self.manifest = original

    def test_unsafe_members(self):
        for name, memberType in (
            ("../escape", tarfile.REGTYPE),
            ("/escape", tarfile.REGTYPE),
            ("mesl-linux-amd64/link", tarfile.SYMTYPE),
            ("mesl-linux-amd64/hard", tarfile.LNKTYPE),
        ):
            buffer = io.BytesIO()
            with tarfile.open(fileobj=buffer, mode="w:gz") as archive:
                member = tarfile.TarInfo(name)
                member.type = memberType
                member.linkname = "target"
                archive.addfile(member)
            with self.assertRaises(ValueError):
                update.InspectArchive(buffer.getvalue(), "amd64", 62)

    def test_fallback_and_malformed_manifests(self):
        def FetchFallback(url, version):
            if url == update.manifestUrls[0]:
                raise OSError("offline")
            return self.Fetch(url, version)

        self.assertEqual(
            update.Discover(self.current, FetchFallback)["version"], self.nextVersion
        )
        with self.assertRaisesRegex(ValueError, "Neither"):
            update.Discover(self.current, lambda *args: b"not json")

    def test_atomic_write_and_failure(self):
        with tempfile.TemporaryDirectory() as temporaryDir:
            filePath = Path(temporaryDir) / "release.json"
            update.AtomicJson(filePath, self.current)
            before = filePath.read_bytes()
            with mock.patch.object(update.os, "replace", side_effect=OSError("failed")):
                with self.assertRaises(OSError):
                    update.AtomicJson(filePath, {"version": self.nextVersion})
            self.assertEqual(filePath.read_bytes(), before)
            self.assertEqual(list(Path(temporaryDir).iterdir()), [filePath])

    def test_version_validation(self):
        for version in (None, "2.0.3-rc1", "v2.0.3", "02.0.3", "2.0", "$(oops)"):
            with self.assertRaises(ValueError):
                update.ParseVersion(version)
