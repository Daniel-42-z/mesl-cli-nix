"""Discover and verify MESL releases without executing downloaded programs."""

import argparse
import base64
import hashlib
import io
import json
import os
import re
import struct
import sys
import tarfile
import tempfile
from pathlib import Path, PurePosixPath
from urllib.parse import urlsplit
from urllib.request import Request, urlopen

manifestUrls = (
    "https://dl-zone1.rlose.com/version/mesl.json",
    "https://version.meslapp.com/version.json",
)
architectures = {"x86_64-linux": ("amd64", 62), "aarch64-linux": ("arm64", 183)}
maxDownloadSize = 128 * 1024 * 1024


def ParseVersion(version):
    if not isinstance(version, str) or not re.fullmatch(
        r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)", version
    ):
        raise ValueError("Expected a stable numeric MAJOR.MINOR.PATCH version")
    return tuple(map(int, version.split(".")))


def SriHash(archiveData):
    return "sha256-" + base64.b64encode(hashlib.sha256(archiveData).digest()).decode()


def Fetch(url, currentVersion):
    if urlsplit(url).scheme != "https":
        raise ValueError("Only HTTPS downloads are allowed")
    request = Request(
        url,
        headers={
            "User-Agent": f"MeslClientForLinux/v{currentVersion}",
            "Accept": "application/json, */*",
        },
    )
    with urlopen(request, timeout=30) as response:
        if urlsplit(response.url).scheme != "https":
            raise ValueError("Refusing a non-HTTPS redirect")
        responseData = response.read(maxDownloadSize + 1)
    if len(responseData) > maxDownloadSize:
        raise ValueError("Download exceeds size limit")
    return responseData


def InspectArchive(archiveData, arch, elfMachine):
    rootName = f"mesl-linux-{arch}"
    required = {"mesl-cli", "mihomo", "geoip.metadb", "README.md", "mesl-cli.service"}
    found = set()
    totalSize = 0
    seen = set()
    with tarfile.open(fileobj=io.BytesIO(archiveData), mode="r:gz") as archive:
        for member in archive:
            memberPath = PurePosixPath(member.name)
            if (
                memberPath.is_absolute()
                or ".." in memberPath.parts
                or not memberPath.parts
                or memberPath.parts[0] != rootName
            ):
                raise ValueError("Unsafe or unexpected archive path")
            if member.name in seen or not (member.isfile() or member.isdir()):
                raise ValueError("Duplicate path, link, or special archive member")
            seen.add(member.name)
            totalSize += member.size
            if totalSize > 256 * 1024 * 1024 or len(seen) > 100:
                raise ValueError("Archive exceeds extraction limits")
            if member.isfile() and len(memberPath.parts) == 2:
                found.add(memberPath.name)
                if memberPath.name in ("mesl-cli", "mihomo"):
                    header = archive.extractfile(member).read(64)
                    if (
                        len(header) != 64
                        or header[:6] != b"\x7fELF\x02\x01"
                        or struct.unpack_from("<H", header, 18)[0] != elfMachine
                    ):
                        raise ValueError("Unexpected ELF architecture")
        if not required <= found:
            raise ValueError("Archive is missing required distribution files")


def AtomicJson(filePath, value):
    filePath = Path(filePath)
    filePath.parent.mkdir(parents=True, exist_ok=True)
    temporaryPath = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w", dir=filePath.parent, delete=False
        ) as temporaryFile:
            temporaryPath = temporaryFile.name
            json.dump(value, temporaryFile, indent=2, ensure_ascii=False)
            temporaryFile.write("\n")
            temporaryFile.flush()
            os.fsync(temporaryFile.fileno())
        os.chmod(temporaryPath, 0o644)
        os.replace(temporaryPath, filePath)
    finally:
        if temporaryPath and os.path.exists(temporaryPath):
            os.unlink(temporaryPath)


def Discover(current, fetch=Fetch):
    currentVersion = current["version"]
    ParseVersion(currentVersion)
    manifest = None
    for manifestUrl in manifestUrls:
        try:
            candidate = json.loads(fetch(manifestUrl, currentVersion))
            linux = candidate["linux"]
            ParseVersion(linux["version"])
            if "error" in candidate:
                raise ValueError("Upstream returned an error")
            manifest = linux
            break
        except (OSError, ValueError, KeyError, TypeError):
            continue
    if manifest is None:
        raise ValueError("Neither MESL version manifest is usable")
    version = manifest["version"]
    if ParseVersion(version) < ParseVersion(currentVersion):
        return None
    sources = {}
    for system, (arch, elfMachine) in architectures.items():
        filename = f"mesl-linux-{arch}.tar.gz"
        url = manifest["urls"][arch]
        if (
            urlsplit(url).scheme != "https"
            or PurePosixPath(urlsplit(url).path).name != filename
        ):
            raise ValueError("Unexpected archive URL")
        fileInfo = manifest["files"][filename]
        hexHash, size = fileInfo["sha256"], fileInfo["size"]
        if not isinstance(hexHash, str) or not re.fullmatch("[0-9a-f]{64}", hexHash):
            raise ValueError("Invalid SHA-256")
        if type(size) is not int or not 0 < size <= maxDownloadSize:
            raise ValueError("Invalid archive size")
        sriHash = "sha256-" + base64.b64encode(bytes.fromhex(hexHash)).decode()
        sources[system] = {"url": url, "hash": sriHash, "size": size}
        if version == currentVersion:
            if any(
                sources[system][key] != current["sources"][system][key]
                for key in ("hash", "size")
            ):
                raise ValueError(
                    "Same-version archive replacement detected; manual investigation required"
                )
            continue
        archiveData = fetch(url, currentVersion)
        if len(archiveData) != size or SriHash(archiveData) != sriHash:
            raise ValueError("Archive checksum or size mismatch")
        InspectArchive(archiveData, arch, elfMachine)
    return (
        None if version == currentVersion else {"version": version, "sources": sources}
    )


def Main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--check", action="store_true")
    mode.add_argument("--write", action="store_true")
    parser.add_argument("--repo", type=Path, default=Path.cwd())
    args = parser.parse_args()
    releasePath = args.repo / "release.json"
    current = json.loads(releasePath.read_text())
    candidate = Discover(current)
    if candidate and args.write:
        AtomicJson(releasePath, candidate)
    print(
        json.dumps(
            {
                "changed": candidate is not None,
                "currentVersion": current["version"],
                "latestVersion": candidate["version"]
                if candidate
                else current["version"],
                "release": candidate,
            }
        )
    )


if __name__ == "__main__":
    try:
        Main()
    except (OSError, ValueError, KeyError, TypeError, tarfile.TarError) as error:
        print(f"MESL update failed: {error}", file=sys.stderr)
        sys.exit(1)
