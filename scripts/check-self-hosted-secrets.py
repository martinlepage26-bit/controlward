#!/usr/bin/env python3
"""Fail if a job that runs on a self-hosted runner can see deploy secrets.

CT920 (the self-hosted runner) is a shared dev box where other people have
root, so anything a job holds there is readable. Only test, typecheck and
scan jobs may run on it. This check fails when a job whose runs-on includes
"self-hosted" (or the "ct920" label):
  - references secrets.<NAME> other than secrets.GITHUB_TOKEN, in the job
    or in workflow-level env,
  - uses `secrets: inherit` or bracket access like secrets['X'],
  - declares a deployment `environment:`,
  - lives in a deploy workflow (file name starting with "deploy" or
    containing "pages-deploy").

Usage: python3 scripts/check-self-hosted-secrets.py [.github/workflows]
       python3 scripts/check-self-hosted-secrets.py --self-test
"""
import pathlib
import re
import sys

import yaml

SECRET_RE = re.compile(r"(?<![\w./-])secrets\s*\.\s*([A-Za-z_][A-Za-z0-9_]*)")
SECRET_BRACKET_RE = re.compile(r"(?<![\w./-])secrets\s*\[")
SELF_HOSTED_LABELS = {"self-hosted", "ct920"}


def _labels(runs_on):
    if runs_on is None:
        return set()
    if isinstance(runs_on, str):
        return {runs_on.strip().lower()}
    if isinstance(runs_on, list):
        return {str(x).strip().lower() for x in runs_on}
    if isinstance(runs_on, dict):
        out = set()
        for key in ("labels", "group"):
            out |= _labels(runs_on.get(key))
        return out
    return {str(runs_on).lower()}


def _is_self_hosted(runs_on):
    labels = _labels(runs_on)
    if labels & SELF_HOSTED_LABELS:
        return True
    # An expression could resolve to a self-hosted label at run time; treat
    # it as self-hosted so it cannot slip past this check.
    return any("${{" in label for label in labels)


def check_workflow(name, text):
    problems = []
    doc = yaml.safe_load(text) or {}
    jobs = doc.get("jobs") or {}
    top_env = yaml.safe_dump(doc.get("env") or {})
    deploy_file = name.lower().startswith("deploy") or "pages-deploy" in name.lower()
    for job_id, job in jobs.items():
        if not isinstance(job, dict) or not _is_self_hosted(job.get("runs-on")):
            continue
        where = f"{name}: job '{job_id}' runs on self-hosted"
        if deploy_file:
            problems.append(f"{where} but this is a deploy workflow")
        if job.get("environment"):
            problems.append(f"{where} but declares environment {job['environment']!r}")
        if job.get("secrets") == "inherit":
            problems.append(f"{where} but uses 'secrets: inherit'")
        body = yaml.safe_dump(job) + top_env
        if SECRET_BRACKET_RE.search(body):
            problems.append(f"{where} but uses bracket secrets access")
        for secret in sorted(set(SECRET_RE.findall(body))):
            if secret != "GITHUB_TOKEN":
                problems.append(f"{where} but references secrets.{secret}")
    return problems


def self_test():
    ok = """
on: [pull_request]
jobs:
  t:
    runs-on: [self-hosted, ct920]
    steps: [{run: "echo ${{ secrets.GITHUB_TOKEN }}"}]
  d:
    runs-on: ubuntu-latest
    steps: [{run: "echo ${{ secrets.CLOUDFLARE_API_TOKEN }}"}]
"""
    bad_cases = {
        "job secret": """
jobs:
  t:
    runs-on: [self-hosted, ct920]
    env: {T: "${{ secrets.CLOUDFLARE_API_TOKEN }}"}
    steps: [{run: echo}]
""",
        "top env": """
env: {T: "${{ secrets.RAILWAY_TOKEN }}"}
jobs:
  t:
    runs-on: self-hosted
    steps: [{run: echo}]
""",
        "inherit": """
jobs:
  t:
    runs-on: {labels: [self-hosted]}
    secrets: inherit
    uses: ./.github/workflows/x.yml
""",
        "environment": """
jobs:
  t:
    runs-on: [self-hosted, ct920]
    environment: production
    steps: [{run: echo}]
""",
        "bracket": """
jobs:
  t:
    runs-on: [self-hosted]
    steps: [{run: "echo ${{ secrets['X'] }}"}]
""",
        "expression runs-on": """
jobs:
  t:
    runs-on: ${{ matrix.r }}
    steps: [{run: "echo ${{ secrets.X }}"}]
""",
    }
    assert check_workflow("tests.yml", ok) == [], check_workflow("tests.yml", ok)
    for label, text in bad_cases.items():
        assert check_workflow("tests.yml", text), f"self-test case not caught: {label}"
    deploy = "jobs:\n  b:\n    runs-on: [self-hosted, ct920]\n    steps: [{run: echo}]\n"
    assert check_workflow("deploy.yml", deploy), "deploy workflow on self-hosted not caught"
    print(f"self-test passed ({len(bad_cases) + 2} cases)")


def main(argv):
    if argv[1:2] == ["--self-test"]:
        self_test()
        return 0
    root = pathlib.Path(argv[1] if len(argv) > 1 else ".github/workflows")
    files = sorted(list(root.glob("*.yml")) + list(root.glob("*.yaml")))
    problems = []
    for path in files:
        problems += check_workflow(path.name, path.read_text())
    for p in problems:
        print(f"::error::{p}")
    print(f"checked {len(files)} workflow files, {len(problems)} problem(s)")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
