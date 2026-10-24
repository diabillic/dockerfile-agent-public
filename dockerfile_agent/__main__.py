"""Entry point: python -m dockerfile_agent [--once | --render PATH]."""

from __future__ import annotations

import argparse
import logging
import os
import time
from pathlib import Path

from .agent import Agent
from .config import Config
from .gitops import Git
from .notice import Outbox
from .render import facts, render
from .state import State

log = logging.getLogger("dockerfile_agent")


def main() -> None:
    ap = argparse.ArgumentParser(prog="dockerfile_agent")
    ap.add_argument("--once", action="store_true", help="run one cycle and exit")
    ap.add_argument("--render", metavar="PATH", help="print the generated files for a local checkout and exit")
    args = ap.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")

    if args.render:
        tz = os.environ.get("TIMEZONE", "").strip() or Config([]).timezone
        for name, text in render(facts(Path(args.render)), Config([]).base_image, tz).items():
            print(f"==> {name}\n{text}")
        return

    cfg = Config.from_env()
    for repo in cfg.repos:
        if not os.path.isfile(cfg.key(repo)):
            log.warning("No deploy key for %s at %s (run deploy/provision.sh)", repo, cfg.key(repo))
    git = Git(os.path.join(os.path.dirname(cfg.state_path), "github_known_hosts"))
    git.pin_github_host_keys()
    agent = Agent(cfg, git, State(cfg.state_path), Outbox(cfg.notify_urls))
    log.info("Starting: repos=%s public=%s poll=%ss grace=%smin base=%s tz=%s", ",".join(cfg.repos), cfg.watch_public,
             cfg.poll_seconds, cfg.public_grace_minutes, cfg.base_image, cfg.timezone)
    while True:
        try:
            agent.cycle()
        except Exception:  # keep watching; the next cycle retries
            log.exception("Cycle failed")
        if args.once:
            return
        time.sleep(cfg.poll_seconds)


if __name__ == "__main__":
    main()
