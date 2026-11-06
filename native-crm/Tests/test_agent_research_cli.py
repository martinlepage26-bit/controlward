"""Focused local handoff tests. No app, network, accounts or normal workspace."""
import argparse
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
import uuid

sys.dont_write_bytecode = True
SCRIPT = Path(__file__).resolve().parents[1] / "Sources/FollowUpOSNative/Resources/Agent/controlward-research.py"
spec = importlib.util.spec_from_file_location("controlward_research", SCRIPT)
client = importlib.util.module_from_spec(spec)
spec.loader.exec_module(client)


class ResearchClientTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def input(self, value):
        path = self.root / "input.json"
        path.write_text(json.dumps(value))
        return path

    def test_only_discovery_fields_and_domain_deduplication(self):
        sites = client.sites_from_file(self.input([{"name": "Example", "url": "https://www.example.test/about?tracking=1#top"}, {"name": "Other label", "url": "https://example.test/contact"}]))
        self.assertEqual(sites, [{"name": "Example", "url": "https://www.example.test/about"}])
        for extra in ("email", "aiUse", "send"):
            with self.assertRaises(ValueError):
                client.sites_from_file(self.input([{"name": "Example", "url": "https://example.test", extra: "untrusted claim"}]))

    def test_private_and_credential_urls_refused(self):
        for url in ("http://127.0.0.1", "https://localhost", "https://host.internal", "file:///etc/hosts", "https://name:password@example.test", "https://example.test:8080"):
            with self.subTest(url=url), self.assertRaises(ValueError):
                client.sites_from_file(self.input([{"name": "Example", "url": url}]))

    def test_atomic_private_job_cannot_overwrite(self):
        path = self.root / "requests" / (str(uuid.uuid4()) + ".json")
        client.private_json(path, {"original": True})
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        with self.assertRaises(FileExistsError):
            client.private_json(path, {"original": False})
        self.assertEqual(json.loads(path.read_text()), {"original": True})
        self.assertEqual(list(path.parent.glob("*.tmp")), [])

    def test_stale_app_cannot_accept_a_submission(self):
        review = str(uuid.uuid4())
        inbox = self.root / "agent-inbox"
        client.private_json(inbox / "available.json", {"schema": 2, "workspaceGeneration": str(uuid.uuid4()), "pid": 1, "mode": "review", "reviewID": review, "build": "test", "updatedAt": "2020-01-01T00:00:00Z"})
        args = argparse.Namespace(live=False, review_id=review, command="submit")
        with self.assertRaises(ValueError):
            client.select_workspace(args, [(inbox, review)])
        args.command = "status"
        _, availability = client.select_workspace(args, [(inbox, review)])
        self.assertFalse(availability["app_running"])

    def test_old_protocol_or_missing_generation_cannot_be_selected(self):
        review = str(uuid.uuid4())
        inbox = self.root / "old-inbox"
        args = argparse.Namespace(live=False, review_id=review, command="status")
        for payload in ({"schema": 1}, {"schema": 2}, {"schema": 2, "workspaceGeneration": str(uuid.uuid1())}):
            path = inbox / "available.json"
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(json.dumps(dict(pid=1, mode="review", reviewID=review, build="test", updatedAt="2020-01-01T00:00:00Z", **payload)))
            with self.assertRaises(ValueError):
                client.select_workspace(args, [(inbox, review)])

    def test_normal_workspace_needs_explicit_flag(self):
        with patch.object(Path, "home", return_value=self.root):
            normal = self.root / "Library/Application Support/ControlWard/leads/agent-inbox"
            self.assertNotIn((normal, None), list(client.workspaces()))
            self.assertIn((normal, None), list(client.workspaces(True)))


if __name__ == "__main__":
    unittest.main()
