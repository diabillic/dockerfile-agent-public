"""The few git operations the agent needs, run with the git CLI.

Private repositories are reached over SSH with a per-repository deploy key (GitHub only allows a
deploy key on one repository); public ones over anonymous HTTPS. GitHub's SSH host keys are
pinned from its HTTPS meta API, never trusted on first use.
"""

from __future__ import annotations

import os
import subprocess
from pathlib import Path

import requests


class GitError(RuntimeError):
    pass


class Git:
    def __init__(self, known_hosts: str):
        self.known_hosts = known_hosts

    def pin_github_host_keys(self) -> None:
        keys = requests.get("https://api.github.com/meta", timeout=20).json()["ssh_keys"]
        Path(self.known_hosts).parent.mkdir(parents=True, exist_ok=True)
        Path(self.known_hosts).write_text("".join(f"github.com {k}\n" for k in keys), encoding="utf-8")

    def run(self, *args: str, cwd: str | None = None, key: str | None = None, timeout: int = 180) -> str:
        env = {**os.environ, "GIT_TERMINAL_PROMPT": "0", "LC_ALL": "C"}
        if key:
            env["GIT_SSH_COMMAND"] = (f"ssh -i {key} -o IdentitiesOnly=yes -o BatchMode=yes "
                                      f"-o UserKnownHostsFile={self.known_hosts} -o StrictHostKeyChecking=yes")
        try:
            res = subprocess.run(["git", *args], cwd=cwd, env=env, capture_output=True, text=True, timeout=timeout)
        except subprocess.TimeoutExpired:
            raise GitError(f"git {args[0]} timed out") from None
        if res.returncode != 0:
            raise GitError(f"git {args[0]} failed: {(res.stderr or res.stdout).strip()[-400:]}")
        return res.stdout

    def head(self, url: str, branch: str, key: str | None = None) -> str:
        out = self.run("ls-remote", url, f"refs/heads/{branch}", key=key, timeout=60).split()
        if not out:
            raise GitError(f"branch {branch} not found")
        return out[0]

    def checkout(self, url: str, path: str, branch: str, key: str | None = None) -> str:
        """Clone or fast-forward `path` to the remote branch; returns the commit."""
        if not (Path(path) / ".git").is_dir():
            Path(path).parent.mkdir(parents=True, exist_ok=True)
            self.run("clone", "-q", "--branch", branch, "--single-branch", url, path, key=key)
        else:
            self.run("remote", "set-url", "origin", url, cwd=path)
            self.run("fetch", "-q", "origin", branch, cwd=path, key=key)
            self.run("checkout", "-q", "-B", branch, f"origin/{branch}", cwd=path)
            self.run("reset", "-q", "--hard", f"origin/{branch}", cwd=path)
            self.run("clean", "-qfdx", cwd=path)
        return self.run("rev-parse", "HEAD", cwd=path).strip()

    def commit_push(self, path: str, files: list[str], message: str, author: str, email: str, branch: str,
                    key: str | None = None) -> str:
        self.run("add", "--", *files, cwd=path)
        self.run("-c", f"user.name={author}", "-c", f"user.email={email}", "commit", "-q", "-m", message, cwd=path)
        self.run("push", "-q", "origin", f"HEAD:{branch}", cwd=path, key=key)  # rejected if main moved: retried
        return self.run("rev-parse", "HEAD", cwd=path).strip()
