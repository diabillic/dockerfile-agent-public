"""Settings from the environment (agent.env, rendered by the deploy workflow)."""

from __future__ import annotations

import os
from dataclasses import dataclass, field
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError


def _int(name: str, default: int) -> int:
    raw = os.environ.get(name, "").strip()
    try:
        return int(raw) if raw else default
    except ValueError:
        raise SystemExit(f"{name} must be a whole number, got {raw!r}") from None


def _bool(name: str, default: bool) -> bool:
    raw = os.environ.get(name, "").strip().lower()
    return default if not raw else raw in ("1", "true", "yes", "on")


def _timezone(name: str) -> str:
    try:
        ZoneInfo(name)
    except (ZoneInfoNotFoundError, ValueError):
        raise SystemExit(f"TIMEZONE must be an IANA zone such as America/New_York, got {name!r}") from None
    return name


def _list(name: str) -> list[str]:
    return [x.strip() for x in os.environ.get(name, "").replace("\n", ",").split(",") if x.strip()]


@dataclass
class Config:
    repos: list[str]  # private owner/name repositories that run an agent; each gets a Dockerfile
    branch: str = "main"
    public_suffix: str = "-public"  # each repo's public copy, watched for direct changes
    watch_public: bool = True
    private_only: list[str] = field(default_factory=list)  # repos without a public copy: not checked
    poll_seconds: int = 60
    public_grace_minutes: int = 20  # a public copy may lag its private repo while the sync runs
    base_image: str = "python:3.13-slim-trixie"
    timezone: str = "UTC"  # the images' clock (TZ), e.g. America/New_York
    author_name: str = "Dockerfile agent"
    author_email: str = "dockerfile-agent@localhost"
    keys_dir: str = "/var/lib/dockerfile-agent/keys"  # <repo name> = that repo's deploy key
    work_dir: str = "/var/lib/dockerfile-agent/work"
    state_path: str = "/var/lib/dockerfile-agent/state.json"
    notify_urls: list[str] = field(default_factory=list)
    ssh_url: str = "git@github.com:{repo}.git"
    https_url: str = "https://github.com/{repo}.git"

    @classmethod
    def from_env(cls) -> "Config":
        repos = _list("REPOS")
        bad = [r for r in repos if r.count("/") != 1 or r.endswith(cls.public_suffix)]
        if not repos or bad:
            raise SystemExit("REPOS must list the private owner/name repositories, e.g. me/agent-a,me/agent-b"
                             + (f" (bad: {', '.join(bad)})" if bad else ""))
        return cls(
            repos=repos,
            branch=os.environ.get("BRANCH", "").strip() or "main",
            public_suffix=os.environ.get("PUBLIC_SUFFIX", "").strip() or "-public",
            watch_public=_bool("WATCH_PUBLIC", True),
            private_only=_list("PRIVATE_ONLY"),
            poll_seconds=max(15, _int("POLL_SECONDS", 60)),
            public_grace_minutes=max(0, _int("PUBLIC_GRACE_MINUTES", 20)),
            base_image=os.environ.get("BASE_IMAGE", "").strip() or cls.base_image,
            timezone=_timezone(os.environ.get("TIMEZONE", "").strip() or cls.timezone),
            author_name=os.environ.get("GIT_AUTHOR_NAME", "").strip() or cls.author_name,
            author_email=os.environ.get("GIT_AUTHOR_EMAIL", "").strip() or cls.author_email,
            keys_dir=os.environ.get("KEYS_DIR", "").strip() or cls.keys_dir,
            work_dir=os.environ.get("WORK_DIR", "").strip() or cls.work_dir,
            state_path=os.environ.get("STATE_PATH", "").strip() or cls.state_path,
            notify_urls=_list("NOTIFY_URLS"),
        )

    def public(self, repo: str) -> str:
        return repo + self.public_suffix

    def key(self, repo: str) -> str:
        return os.path.join(self.keys_dir, repo.split("/")[1])
