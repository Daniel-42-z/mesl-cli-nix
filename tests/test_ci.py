import json
import os
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import ci
import update


class CandidateTests(unittest.TestCase):
    def setUp(self):
        self.temporaryDir = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporaryDir.cleanup)
        self.root = Path(self.temporaryDir.name)
        self.repo = self.root / "repo"
        self.repo.mkdir()
        self.artifactDir = self.root / "artifact"
        self.evidenceDir = self.root / "evidence"
        self.environment = mock.patch.dict(
            os.environ, {"JJ_USER": "Test Bot", "JJ_EMAIL": "test@example.com"}
        )
        self.environment.start()
        self.addCleanup(self.environment.stop)
        ci.Jj(self.repo, "git", "init", "--colocate")
        self.release = json.loads(
            (Path(__file__).resolve().parents[1] / "release.json").read_text()
        )
        update.AtomicJson(self.repo / "release.json", self.release)
        ci.Jj(self.repo, "describe", "-m", "Baseline")
        ci.Jj(self.repo, "new")

    def PrepareRelease(self):
        candidate = dict(self.release, version="9999.0.0")
        with (
            mock.patch.object(ci, "Discover", return_value=candidate),
            mock.patch.object(ci, "RemoteHead", return_value=None),
        ):
            result = ci.Prepare(self.repo, self.artifactDir)
        self.assertEqual(result["kind"], "release")
        return ci.Verify(self.repo, self.artifactDir)

    def MakeEvidence(self, identity):
        for suite in ci.requiredSuites:
            update.AtomicJson(
                self.evidenceDir / f"{suite}.json",
                {"suite": suite, "result": "success", "identity": identity},
            )

    def test_candidate_roundtrip_and_tamper(self):
        identity = self.PrepareRelease()
        restored = self.root / "restored"
        ci.Restore(restored, self.artifactDir)
        self.assertEqual(ci.Verify(restored, self.artifactDir), identity)
        (restored / "release.json").write_text("tampered")
        with self.assertRaisesRegex(ValueError, "digest"):
            ci.Verify(restored, self.artifactDir)

    def test_checkout_roundtrip(self):
        result = ci.Prepare(self.repo, self.artifactDir, checkout=True)
        self.assertEqual(result["kind"], "checkout")
        restored = self.root / "restored"
        ci.Restore(restored, self.artifactDir)
        ci.Verify(restored, self.artifactDir)

    def test_evidence_missing_mismatched_duplicate_failed(self):
        identity = self.PrepareRelease()
        with self.assertRaisesRegex(ValueError, "Missing"):
            ci.Gate(identity, self.evidenceDir)
        self.MakeEvidence(identity)
        ci.Gate(identity, self.evidenceDir)
        recordPath = self.evidenceDir / "amd64.json"
        original = recordPath.read_text()
        for key, value in (("identity", {}), ("result", "failure")):
            record = json.loads(original)
            record[key] = value
            update.AtomicJson(recordPath, record)
            with self.assertRaises(ValueError):
                ci.Gate(identity, self.evidenceDir)
        recordPath.write_text(original)
        (self.evidenceDir / "duplicate.json").write_text(original)
        with self.assertRaisesRegex(ValueError, "Duplicate"):
            ci.Gate(identity, self.evidenceDir)

    def test_remote_changes_block_publication(self):
        identity = self.PrepareRelease()
        self.MakeEvidence(identity)
        with (
            mock.patch.dict(os.environ, {"DEFAULT_BRANCH": "main"}),
            mock.patch.object(ci, "RemoteHead", return_value="advanced"),
            mock.patch.object(ci, "Gh") as githubCall,
        ):
            with self.assertRaisesRegex(ValueError, "advanced"):
                ci.Publish(self.repo, self.artifactDir, self.evidenceDir)
            githubCall.assert_not_called()

    def test_publish_exact_head(self):
        identity = self.PrepareRelease()
        self.MakeEvidence(identity)

        def FakeGh(repo, *arguments, **kwargs):
            if arguments[:2] == ("pr", "list"):
                return "[]"
            if "/pulls" in arguments[-1]:
                return '{"number": 12}'
            return "{}"

        parent, commit = identity["parent"], identity["commit"]
        environment = {
            "DEFAULT_BRANCH": "main",
            "GH_TOKEN": "test-token",
            "GH_REPO": "owner/repo",
            "RUN_URL": "https://example.com/run",
        }
        with (
            mock.patch.dict(os.environ, environment),
            mock.patch.object(
                ci,
                "RemoteHead",
                side_effect=[parent, None, None, parent, commit, parent],
            ),
            mock.patch.object(ci, "Jj") as vcsCall,
            mock.patch.object(ci, "Verify", return_value=identity),
            mock.patch.object(ci, "Gh", side_effect=FakeGh) as githubCall,
        ):
            ci.Publish(self.repo, self.artifactDir, self.evidenceDir)
        self.assertTrue(
            any(
                call.args[1:4] == ("git", "push", "--remote")
                for call in vcsCall.call_args_list
            )
        )
        mergeCall = githubCall.call_args_list[-1]
        self.assertEqual(mergeCall.args[-3:], ("--match-head-commit", commit, "--auto"))

    def test_merge_retries_only_clean_status_with_same_head(self):
        cleanError = subprocess.CalledProcessError(
            1, "gh", stderr="GraphQL: Pull request Pull request is in clean status"
        )
        with (
            mock.patch.dict(os.environ, {"GH_REPO": "owner/repo"}),
            mock.patch.object(ci, "Gh", side_effect=[cleanError, ""]) as githubCall,
        ):
            ci.RequestMerge(self.repo, "12", "candidate-sha")
        first, retry = githubCall.call_args_list
        self.assertEqual(first.args[:-1], retry.args)
        self.assertEqual(first.args[-1], "--auto")
        self.assertEqual(retry.args[-2:], ("--match-head-commit", "candidate-sha"))

        otherError = subprocess.CalledProcessError(1, "gh", stderr="permission denied")
        with (
            mock.patch.dict(os.environ, {"GH_REPO": "owner/repo"}),
            mock.patch.object(ci, "Gh", side_effect=otherError) as githubCall,
        ):
            with self.assertRaises(subprocess.CalledProcessError):
                ci.RequestMerge(self.repo, "12", "candidate-sha")
        self.assertEqual(githubCall.call_count, 1)

    def test_race_during_fetch_blocks_push(self):
        identity = self.PrepareRelease()
        self.MakeEvidence(identity)
        environment = {"DEFAULT_BRANCH": "main", "GH_TOKEN": "test-token"}
        with (
            mock.patch.dict(os.environ, environment),
            mock.patch.object(ci, "Verify", return_value=identity),
            mock.patch.object(
                ci, "RemoteHead", side_effect=[identity["parent"], None, "raced"]
            ),
            mock.patch.object(ci, "Jj") as vcsCall,
        ):
            with self.assertRaisesRegex(ValueError, "during fetch"):
                ci.Publish(self.repo, self.artifactDir, self.evidenceDir)
        self.assertEqual(len(vcsCall.call_args_list), 1)
        self.assertEqual(vcsCall.call_args.args[1:3], ("git", "fetch"))

    def test_remote_lookup_distinguishes_absence_from_failure(self):
        with mock.patch.dict(os.environ, {"GH_REPO": "owner/repo"}):
            for status in (404, 403, 500):
                error = subprocess.CalledProcessError(
                    1, "gh", output=json.dumps({"status": str(status)})
                )
                with mock.patch.object(ci, "Gh", side_effect=error):
                    if status == 404:
                        self.assertIsNone(ci.RemoteHead(self.repo, "mesl-update"))
                    else:
                        with self.assertRaises(subprocess.CalledProcessError):
                            ci.RemoteHead(self.repo, "mesl-update")

    def test_real_jujutsu_push_and_refresh(self):
        ci.Jj(self.repo, "bookmark", "set", "main", "-r", "@-")

        def LocalHead(repo, branch):
            try:
                return ci.Commit(self.repo, branch)
            except subprocess.CalledProcessError:
                return None

        def FakeGh(repo, *arguments, **kwargs):
            if arguments[:2] == ("pr", "list"):
                return "[]"
            if arguments[-1].endswith("/pulls"):
                return '{"number": 12}'
            return "{}"

        environment = {
            "DEFAULT_BRANCH": "main",
            "GH_TOKEN": "test-token",
            "GH_REPO": "owner/repo",
            "RUN_URL": "https://example.com/run",
        }
        for version in ("9999.0.0", "10000.0.0"):
            clone = self.root / version
            artifactDir = self.root / (version + "-artifact")
            evidenceDir = self.root / (version + "-evidence")
            ci.Jj(
                self.root,
                "git",
                "clone",
                "--colocate",
                str(self.repo / ".git"),
                str(clone),
            )
            candidate = dict(self.release, version=version)
            with (
                mock.patch.object(ci, "Discover", return_value=candidate),
                mock.patch.object(ci, "RemoteHead", side_effect=LocalHead),
            ):
                ci.Prepare(clone, artifactDir)
            identity = ci.Verify(clone, artifactDir)
            for suite in ci.requiredSuites:
                ci.Record(clone, artifactDir, evidenceDir, suite)
            with (
                mock.patch.dict(os.environ, environment),
                mock.patch.object(ci, "RemoteHead", side_effect=LocalHead),
                mock.patch.object(ci, "Gh", side_effect=FakeGh),
            ):
                ci.Publish(clone, artifactDir, evidenceDir)
            self.assertEqual(ci.Commit(self.repo, "mesl-update"), identity["commit"])

    def test_heartbeat_boundaries_and_discovery_failure(self):
        now = datetime.now(timezone.utc)
        self.assertFalse(ci.DueHeartbeat(now - timedelta(days=29), now))
        self.assertTrue(ci.DueHeartbeat(now - timedelta(days=30), now))
        with mock.patch.object(
            ci, "Discover", side_effect=ValueError("upstream unavailable")
        ):
            result = ci.Prepare(self.repo, self.artifactDir)
        self.assertEqual(result, {"changed": "false", "discoveryFailed": "true"})
        originalJj = ci.Jj

        def OldTimestamp(repo, *arguments, **kwargs):
            if arguments[:1] == ("log",) and "committer.timestamp" in arguments[-1]:
                return (now - timedelta(days=31)).strftime("%Y-%m-%dT%H:%M:%SZ")
            return originalJj(repo, *arguments, **kwargs)

        with (
            mock.patch.object(ci, "Jj", side_effect=OldTimestamp),
            mock.patch.object(ci, "Discover", side_effect=ValueError("offline")),
            mock.patch.object(ci, "RemoteHead", return_value=None),
        ):
            result = ci.Prepare(self.repo, self.artifactDir)
        self.assertEqual(result["kind"], "heartbeat")
        self.assertEqual(result["discoveryFailed"], "true")
        identity = ci.Verify(self.repo, self.artifactDir)
        self.assertEqual(
            ci.ChangedPaths(self.repo, identity["parent"], identity["commit"]),
            {".github/update-heartbeat.json"},
        )

    def test_unexpected_changes_rejected(self):
        self.PrepareRelease()
        (self.repo / "unexpected.nix").write_text("{}")
        with self.assertRaisesRegex(ValueError, "differs"):
            ci.Verify(self.repo, self.artifactDir)
