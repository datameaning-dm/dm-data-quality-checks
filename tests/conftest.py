"""Helpers for running the integration project with dbt on DuckDB. No warehouse account needed."""
import os
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[1]
PROJECT = REPO / "integration_tests"
SNAPSHOTS = Path(__file__).resolve().parent / "snapshots"
DBT = str(Path(sys.executable).parent / "dbt")


def run_dbt(args, cwd=PROJECT, vars=None, quiet=True, check=True):
    cmd = [DBT, "--no-use-colors"]
    if quiet:
        cmd.append("--quiet")
    cmd += list(args) + ["--profiles-dir", "ci_profiles", "--no-partial-parse"]
    if vars:
        cmd += ["--vars", repr(vars).replace("'", '"').replace("True", "true").replace("False", "false")]
    proc = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)
    if check and proc.returncode != 0:
        raise AssertionError(f"dbt {' '.join(args)} failed:\n{proc.stdout}\n{proc.stderr}")
    return proc


def match_snapshot(name, text):
    """Compare with tests/snapshots/<name>. UPDATE_SNAPSHOTS=1 rewrites the file instead."""
    path = SNAPSHOTS / name
    if os.environ.get("UPDATE_SNAPSHOTS") == "1" or not path.exists():
        path.write_text(text)
    assert text == path.read_text(), f"{name} changed. Review the diff; UPDATE_SNAPSHOTS=1 accepts it."


@pytest.fixture(scope="session")
def project():
    """The integration project with packages installed, seeded and built (platform: local)."""
    run_dbt(["deps"])
    run_dbt(["seed"], vars={"native_dq_platform": "local"})
    run_dbt(["build"], vars={"native_dq_platform": "local"})
    return PROJECT


@pytest.fixture(scope="session")
def scratch_project(tmp_path_factory):
    """A copy of the integration project to add broken rules to."""
    dest = tmp_path_factory.mktemp("it") / "project"
    shutil.copytree(
        PROJECT, dest,
        ignore=shutil.ignore_patterns("target", "dbt_packages", "logs", "*.duckdb", "*.wal", "package-lock.yml"),
    )
    (dest / "packages.yml").write_text(f"packages:\n  - local: {REPO}\n")
    run_dbt(["deps"], cwd=dest)
    return dest
