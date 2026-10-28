"""Prepare, verify, and publish candidate-bound update evidence."""

import argparse
import base64
import hashlib
import json
import os
import subprocess
import tarfile
from datetime import datetime, timedelta, timezone
from pathlib import Path
from urllib.parse import quote

from update import AtomicJson, Discover, ParseVersion

requiredSuites = {"amd64", "arm64", "vm"}


def Run(command, repo, **kwargs):
    return subprocess.check_output(command, cwd=repo, text=True, **kwargs).strip()


def Jj(repo, *arguments, **kwargs):
    return Run(["jj", "--no-pager", *arguments], repo, **kwargs)


def Commit(repo, revision):
    return Jj(repo, "log", "-r", revision, "--no-graph", "-T", "commit_id")


def TrackedFiles(repo, revision):
    return Jj(repo, "file", "list", "-r", revision).splitlines()


def SourceDigest(repo, revision):
    digest = hashlib.sha256()
    for name in sorted(TrackedFiles(repo, revision)):
        filePath = repo / name
        if filePath.is_symlink() or not filePath.is_file():
            raise ValueError("Candidate contains a symlink or missing file")
        digest.update(
            json.dumps(
                [
                    name,
                    filePath.stat().st_mode & 0o111,
                    hashlib.sha256(filePath.read_bytes()).hexdigest(),
                ]
            ).encode()
            + b"\n"
        )
    return digest.hexdigest()


def ChangedPaths(repo, parent, commit):
    summary = Jj(repo, "diff", "--from", parent, "--to", commit, "--summary")
    return {line[2:] for line in summary.splitlines()}


def DueHeartbeat(lastCommitTime, now):
    return now - lastCommitTime >= timedelta(days=30)


def Verify(repo, artifactDir):
    identity = json.loads((artifactDir / "identity.json").read_text())
    commit, parent, kind = identity["commit"], identity["parent"], identity["kind"]
    if (
        Commit(repo, commit) != commit
        or SourceDigest(repo, commit) != identity["digest"]
    ):
        raise ValueError("Candidate identity or source digest mismatch")
    if Jj(repo, "diff", "--from", commit, "--summary"):
        raise ValueError("Workspace differs from candidate")
    if kind != "checkout":
        if Commit(repo, f"parents({commit})") != parent:
            raise ValueError("Candidate has an unexpected parent")
        expectedPath = (
            "release.json" if kind == "release" else ".github/update-heartbeat.json"
        )
        if kind not in {"release", "heartbeat"} or ChangedPaths(
            repo, parent, commit
        ) != {expectedPath}:
            raise ValueError("Candidate changed unexpected files")
        if kind == "release":
            baseline = json.loads(
                Jj(repo, "file", "show", "-r", parent, "release.json")
            )
            release = json.loads((repo / "release.json").read_text())
            if ParseVersion(release["version"]) <= ParseVersion(baseline["version"]):
                raise ValueError("Release candidate is not newer")
        else:
            heartbeat = json.loads((repo / expectedPath).read_text())
            timestamp = datetime.fromisoformat(heartbeat["lastHeartbeat"])
            now = datetime.now(timezone.utc)
            if set(heartbeat) != {"lastHeartbeat"} or not now - timedelta(
                days=2
            ) <= timestamp <= now + timedelta(minutes=5):
                raise ValueError("Invalid heartbeat timestamp")
    return identity


def Gh(repo, *arguments, payload=None):
    command = ["gh", *arguments]
    if payload is not None:
        command.extend(["--input", "-"])
    return Run(
        command, repo, input=json.dumps(payload) if payload is not None else None
    )


def RemoteHead(repo, branch):
    try:
        result = Gh(
            repo,
            "api",
            f"repos/{os.environ['GH_REPO']}/git/ref/heads/{quote(branch, safe='')}",
        )
        return json.loads(result)["object"]["sha"]
    except subprocess.CalledProcessError as error:
        # Distinguish absent references from authentication/rate-limit failures.
        if error.output and '"status":"404"' in error.output.replace(" ", ""):
            return None
        raise


def Prepare(repo, artifactDir, checkout=False):
    if not (repo / ".jj").exists():
        Jj(repo, "git", "init", "--colocate")
    parent = Commit(repo, "@-")
    discoveryError = ""
    if checkout:
        kind, commit = "checkout", parent
    else:
        current = json.loads((repo / "release.json").read_text())
        candidate = None
        try:
            candidate = Discover(current)
        except (
            OSError,
            ValueError,
            KeyError,
            TypeError,
            tarfile.TarError,
            EOFError,
        ) as error:
            discoveryError = str(error)
            print("MESL discovery failed:", discoveryError)
        commitTime = Jj(
            repo,
            "log",
            "-r",
            parent,
            "--no-graph",
            "-T",
            'committer.timestamp().utc().format("%Y-%m-%dT%H:%M:%SZ")',
        )
        now = datetime.now(timezone.utc)
        if candidate:
            kind = "release"
            AtomicJson(repo / "release.json", candidate)
            description = f"Update MESL to {candidate['version']}"
        elif DueHeartbeat(datetime.fromisoformat(commitTime), now):
            kind = "heartbeat"
            AtomicJson(
                repo / ".github/update-heartbeat.json",
                {"lastHeartbeat": now.isoformat(timespec="seconds")},
            )
            description = "Maintain MESL update schedule activity"
        else:
            return {
                "changed": "false",
                "discoveryFailed": str(bool(discoveryError)).lower(),
            }
        Jj(repo, "describe", "-m", description)
        commit = Commit(repo, "@")
    branch = "mesl-update" if kind == "release" else "mesl-heartbeat"
    identity = {
        "commit": commit,
        "parent": parent,
        "kind": kind,
        "digest": SourceDigest(repo, commit),
        "branch": branch,
        "previousHead": RemoteHead(repo, branch) if not checkout else None,
    }
    artifactDir.mkdir(parents=True, exist_ok=True)
    AtomicJson(artifactDir / "identity.json", identity)
    Verify(repo, artifactDir)
    # The artifact is outside the working copy. Checkout never persists credentials.
    with tarfile.open(artifactDir / "source.tar.gz", "w:gz") as archive:
        for name in [*TrackedFiles(repo, commit), ".git", ".jj"]:
            archive.add(repo / name, arcname=name, recursive=True)
    return {
        "changed": "true",
        "kind": kind,
        "discoveryFailed": str(bool(discoveryError)).lower(),
    }


def Restore(repo, artifactDir):
    repo.mkdir(parents=True, exist_ok=True)
    with tarfile.open(artifactDir / "source.tar.gz", "r:gz") as archive:
        archive.extractall(repo, filter="data")


def Record(repo, artifactDir, evidenceDir, suite):
    identity = Verify(repo, artifactDir)
    if suite not in requiredSuites:
        raise ValueError("Unknown validation suite")
    AtomicJson(
        evidenceDir / f"{suite}.json",
        {"suite": suite, "result": "success", "identity": identity},
    )


def Gate(identity, evidenceDir):
    expected = {"heartbeat"} if identity["kind"] == "heartbeat" else requiredSuites
    evidence = {}
    for filePath in evidenceDir.rglob("*.json"):
        record = json.loads(filePath.read_text())
        suite = record["suite"]
        if (
            suite in evidence
            or record["result"] != "success"
            or record["identity"] != identity
        ):
            raise ValueError("Duplicate, failed, or mismatched validation evidence")
        evidence[suite] = record
    if set(evidence) != expected:
        raise ValueError("Missing validation evidence")


def Publish(repo, artifactDir, evidenceDir):
    identity = Verify(repo, artifactDir)
    if identity["kind"] not in {"release", "heartbeat"}:
        raise ValueError("Only scheduled update candidates may publish")
    Gate(identity, evidenceDir)
    defaultBranch = os.environ["DEFAULT_BRANCH"]
    branch, commit, parent = identity["branch"], identity["commit"], identity["parent"]
    if (
        RemoteHead(repo, defaultBranch) != parent
        or RemoteHead(repo, branch) != identity["previousHead"]
    ):
        raise ValueError(
            "Default branch or update branch advanced; prepare and validate again"
        )
    # Jujutsu uses its Git transport; credentials exist only in this process environment.
    pushEnvironment = os.environ.copy()
    pushEnvironment.update(
        {
            "GIT_CONFIG_COUNT": "1",
            "GIT_CONFIG_KEY_0": "http.https://github.com/.extraHeader",
            "GIT_CONFIG_VALUE_0": "AUTHORIZATION: basic "
            + base64.b64encode(
                ("x-access-token:" + os.environ["GH_TOKEN"]).encode()
            ).decode(),
        }
    )
    Jj(repo, "git", "fetch", "--remote", "origin", env=pushEnvironment)
    if (
        RemoteHead(repo, branch) != identity["previousHead"]
        or RemoteHead(repo, defaultBranch) != parent
    ):
        raise ValueError("Remote changed during fetch; refusing to replace it")
    if identity["previousHead"]:
        Jj(repo, "bookmark", "track", branch, "--remote", "origin")
    Jj(repo, "bookmark", "set", branch, "-r", commit, "--allow-backwards")
    Jj(
        repo,
        "git",
        "push",
        "--remote",
        "origin",
        "--bookmark",
        branch,
        env=pushEnvironment,
    )
    if RemoteHead(repo, branch) != commit or RemoteHead(repo, defaultBranch) != parent:
        raise ValueError("Remote changed before status publication")
    Gh(
        repo,
        "api",
        "--method",
        "POST",
        f"repos/{os.environ['GH_REPO']}/statuses/{commit}",
        payload={
            "state": "success",
            "context": "mesl-update/validated",
            "target_url": os.environ["RUN_URL"],
            "description": "Exact candidate passed all applicable validation suites",
        },
    )
    title = (
        "Maintain update schedule activity"
        if identity["kind"] == "heartbeat"
        else "Update MESL to "
        + json.loads((repo / "release.json").read_text())["version"]
    )
    body = (
        f"{title}.\n\nValidated commit: `{commit}`\n\n[Validation evidence]({os.environ['RUN_URL']}).\n\n"
        + (
            "Only the heartbeat timestamp changes; package sources and configuration are unchanged."
            if identity["kind"] == "heartbeat"
            else "Native AMD64/ARM64 package checks, module evaluation, updater tests, linting, and fresh service VMs passed. Account login and subscription-based routing are not covered."
        )
    )
    pullRequests = json.loads(
        Gh(
            repo,
            "pr",
            "list",
            "--repo",
            os.environ["GH_REPO"],
            "--head",
            branch,
            "--base",
            defaultBranch,
            "--state",
            "open",
            "--json",
            "number",
        )
    )
    if pullRequests:
        pullNumber = str(pullRequests[0]["number"])
        bodyPath = artifactDir / "body.md"
        bodyPath.write_text(body)
        Gh(
            repo,
            "pr",
            "edit",
            pullNumber,
            "--repo",
            os.environ["GH_REPO"],
            "--title",
            title,
            "--body-file",
            str(bodyPath),
        )
    else:
        result = json.loads(
            Gh(
                repo,
                "api",
                "--method",
                "POST",
                f"repos/{os.environ['GH_REPO']}/pulls",
                payload={
                    "title": title,
                    "head": branch,
                    "base": defaultBranch,
                    "body": body,
                },
            )
        )
        pullNumber = str(result["number"])
    Gh(
        repo,
        "pr",
        "merge",
        pullNumber,
        "--repo",
        os.environ["GH_REPO"],
        "--auto",
        "--squash",
        "--match-head-commit",
        commit,
    )


def Main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "command",
        choices=[
            "prepare",
            "restore",
            "verify",
            "record",
            "heartbeat-record",
            "gate",
            "publish",
        ],
    )
    parser.add_argument("--repo", type=Path, default=Path.cwd())
    parser.add_argument("--artifact-dir", type=Path, required=True)
    parser.add_argument("--evidence-dir", type=Path)
    parser.add_argument("--suite", choices=sorted(requiredSuites))
    parser.add_argument("--checkout", action="store_true")
    args = parser.parse_args()
    repo, artifactDir = args.repo.resolve(), args.artifact_dir.resolve()
    evidenceDir = (
        args.evidence_dir.resolve() if args.evidence_dir else artifactDir / "evidence"
    )
    if args.command == "prepare":
        result = Prepare(repo, artifactDir, args.checkout)
        if os.environ.get("GITHUB_OUTPUT"):
            with open(os.environ["GITHUB_OUTPUT"], "a") as outputFile:
                for name, value in result.items():
                    outputFile.write(f"{name}={value}\n")
        print(json.dumps(result))
    elif args.command == "restore":
        Restore(repo, artifactDir)
    elif args.command == "record":
        Record(repo, artifactDir, evidenceDir, args.suite)
    elif args.command == "heartbeat-record":
        identity = Verify(repo, artifactDir)
        if identity["kind"] != "heartbeat":
            raise ValueError("Expected heartbeat candidate")
        AtomicJson(
            evidenceDir / "heartbeat.json",
            {"suite": "heartbeat", "result": "success", "identity": identity},
        )
    elif args.command == "verify":
        print(json.dumps(Verify(repo, artifactDir)))
    elif args.command == "gate":
        Gate(Verify(repo, artifactDir), evidenceDir)
    else:
        Publish(repo, artifactDir, evidenceDir)


if __name__ == "__main__":
    Main()
