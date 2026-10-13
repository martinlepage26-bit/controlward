#!/usr/bin/env python3
"""Regression checks for secret access and the self-hosted job's preflight."""
import importlib.util
import pathlib
import unittest

import yaml

ROOT = pathlib.Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("guard", ROOT / "scripts/check-self-hosted-secrets.py")
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)


class SecretsGuardTests(unittest.TestCase):
    def workflow(self, expression, top_level=False):
        job = {"runs-on": ["self-hosted", "ct920"], "steps": [{"run": "echo synthetic"}]}
        doc = {"jobs": {"test": job}}
        (doc if top_level else job)["env"] = {"EXAMPLE": "${{ " + expression + " }}"}
        return yaml.safe_dump(doc)

    def test_rejects_secret_context_variants(self):
        for expression in (
            "toJSON(secrets)", "secrets", "toJSON(secrets.*)",
            "SECRETS.EXAMPLE_DEPLOY_KEY", "secrets['EXAMPLE_DEPLOY_KEY']",
            "secrets[format('{0}', 'EXAMPLE_DEPLOY_KEY')]",
            "format('{0}', secrets)",
            "secrets.GITHUB_TOKEN || toJSON(secrets)",
            "secrets.GITHUB_TOKEN_SUFFIX", "toJSON(SeCrEtS)",
            "format('}} {0}', secrets)", "format('it''s {0}', secrets)",
            "secrets.GITHUB_TOKEN }} ${{ toJSON(secrets)",
        ):
            for top_level in (False, True):
                with self.subTest(expression=expression, top_level=top_level):
                    self.assertTrue(guard.check_workflow("ci.yml", self.workflow(expression, top_level)))

    def test_allows_only_explicit_github_token_access(self):
        for expression in ("secrets.GITHUB_TOKEN", "secrets.github_token", "SECRETS.GITHUB_TOKEN",
                           "format('Bearer {0}', secrets.GITHUB_TOKEN)"):
            with self.subTest(expression=expression):
                self.assertEqual(guard.check_workflow("ci.yml", self.workflow(expression)), [])

    def test_literal_secret_names_are_not_context_access(self):
        self.assertEqual(guard.check_workflow("ci.yml", self.workflow("'secrets.EXAMPLE_KEY'")), [])
        self.assertEqual(guard.check_workflow("ci.yml", self.workflow("vars.secrets")), [])

    def test_ci_runs_preflight_before_self_hosted_work(self):
        doc = yaml.safe_load((ROOT / ".github/workflows/ci.yml").read_text())
        jobs = doc["jobs"]
        preflight = jobs["runner-secrets-guard"]
        self.assertEqual(preflight["runs-on"], "ubuntu-latest")
        self.assertNotIn("env", doc, "Workflow env must not inject secrets into the preflight")
        self.assertNotIn("continue-on-error", preflight)
        for job_id, job in jobs.items():
            if guard._is_self_hosted(job.get("runs-on")):
                with self.subTest(job=job_id):
                    needs = job.get("needs", [])
                    if isinstance(needs, str):
                        needs = [needs]
                    self.assertIn("runner-secrets-guard", needs)
                    self.assertNotIn("if", job, "Do not bypass the default success dependency")


if __name__ == "__main__":
    unittest.main()
