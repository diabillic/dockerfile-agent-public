import pathlib
import re
import shutil
import subprocess

import pytest

from dockerfile_agent.agent import ERROR_AFTER, Agent
from dockerfile_agent.config import Config
from dockerfile_agent.gitops import Git
from dockerfile_agent.render import NotAnAgent, facts, render
from dockerfile_agent.state import State

BASE = "python:3.13-slim-trixie"
UNIT = """#!/usr/bin/env bash
UNIT=/etc/systemd/system/demo-agent.service
cat > "$UNIT" <<'EOF'
[Unit]
Description=Demo agent

[Service]
Type=simple
User=demo-agent
Group=demo-agent
Environment=STATE_PATH=/var/lib/demo-agent/state.json
EnvironmentFile=/etc/demo-agent/agent.env
WorkingDirectory=/opt/demo-agent/app
ExecStart=/opt/demo-agent/venv/bin/python -m demo_agent
StateDirectory=demo-agent
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
"""


def make_agent_repo(root: pathlib.Path, packages="python3 python3-venv rsync sudo openssh-server openssh-client ca-certificates"):
    (root / "deploy" / "lxc").mkdir(parents=True)
    (root / "demo_agent").mkdir()
    (root / "deploy" / "lxc" / "demo-agent-install").write_text(UNIT, newline="\n")
    (root / "deploy" / "lxc" / "bootstrap-agent.sh").write_text(
        f"apt-get update -qq\napt-get install -y -qq {packages} >/dev/null\n", newline="\n")
    (root / "requirements.txt").write_text("requests==2.34.2\n", newline="\n")
    (root / "demo_agent" / "__main__.py").write_text("print('hi')\n", newline="\n")
    (root / "demo_agent" / "config.py").write_text(
        'port = _int("AGENT_BUS_PORT", 8765)\nknown_hosts: str = "/etc/demo-agent/known_hosts"\n'
        'env_file = "/etc/demo-agent/agent.env"\n', newline="\n")


def git(*args, cwd):
    subprocess.run(["git", "-c", "user.name=t", "-c", "user.email=t@example.com", *args], cwd=cwd, check=True,
                   capture_output=True)


def remote_with(tmp_path, name, populate):
    """A bare repository at remotes/<name>.git whose main holds what populate() wrote."""
    bare = tmp_path / "remotes" / f"{name}.git"
    bare.parent.mkdir(parents=True, exist_ok=True)
    git("init", "-q", "--bare", "-b", "main", str(bare), cwd=tmp_path)
    work = tmp_path / "seed" / name
    work.mkdir(parents=True)
    git("init", "-q", "-b", "main", cwd=work)
    populate(work)
    git("add", "-A", cwd=work)
    git("commit", "-q", "-m", "init", cwd=work)
    git("push", "-q", str(bare), "main", cwd=work)
    return bare


def push_change(tmp_path, bare, change):
    edits = tmp_path / "edit"
    work = edits / str(len(list(edits.glob("*"))) if edits.exists() else 0)  # fresh clone each time
    git("clone", "-q", str(bare), str(work), cwd=tmp_path)
    change(work)
    git("commit", "-qam", "change", cwd=work)
    git("push", "-q", "origin", "main", cwd=work)


def show(bare, path):
    res = subprocess.run(["git", "show", f"main:{path}"], cwd=bare, capture_output=True, text=True)
    return res.stdout if res.returncode == 0 else None


class FakeOutbox:
    def __init__(self):
        self.sent = []

    def send(self, msg):
        self.sent.append(msg)
        return True


def make_agent(tmp_path, repos=("me/demo",), clock=None):
    remotes = str(tmp_path / "remotes")
    cfg = Config(list(repos), work_dir=str(tmp_path / "work"), keys_dir=str(tmp_path / "keys"),
                 state_path=str(tmp_path / "state.json"), ssh_url=remotes + "/{repo}.git",
                 https_url=remotes + "/{repo}.git", public_grace_minutes=20)
    out = FakeOutbox()
    agent = Agent(cfg, Git(str(tmp_path / "kh")), State(cfg.state_path), out, clock or (lambda: 1000.0))
    return agent, out


# --- rendering ---

def test_render_follows_the_deployment_files(tmp_path):
    make_agent_repo(tmp_path)
    f = facts(tmp_path)
    assert (f.name, f.module, f.user, f.workdir) == ("demo-agent", "demo_agent", "demo-agent", "/opt/demo-agent/app")
    assert f.packages == ["ca-certificates", "openssh-client"]  # LXC-only packages dropped
    assert f.ports == [8765] and f.mounts == ["/etc/demo-agent/known_hosts"]  # env file isn't a mount
    assert f.state_dirs == ["/var/lib/demo-agent"] and f.env == {"STATE_PATH": "/var/lib/demo-agent/state.json"}
    out = render(f, BASE)
    df = out["Dockerfile"]
    assert f"FROM {BASE}" in df and "apt-get install -y --no-install-recommends ca-certificates openssh-client tzdata" in df
    assert "ARG PATCHED_AT=unknown" in df and " && apt-get -y full-upgrade \\" in df  # base OS patched every build
    assert 'CMD ["python", "-m", "demo_agent"]' in df and "USER demo-agent" in df and "EXPOSE 8765" in df
    assert 'VOLUME ["/var/lib/demo-agent"]' in df and "ENV STATE_PATH=/var/lib/demo-agent/state.json" in df
    assert "-v /path/to/known_hosts:/etc/demo-agent/known_hosts:ro" in df
    assert out[".dockerignore"].splitlines()[1:4] == ["*", "!requirements.txt", "!demo_agent/"]
    assert render(facts(tmp_path), BASE) == out  # deterministic
    assert "ENV TZ=UTC" in df and "ca-certificates openssh-client tzdata" in df
    est = render(f, BASE, "America/New_York")["Dockerfile"]
    assert "ENV TZ=America/New_York" in est and 'ln -snf "/usr/share/zoneinfo/$TZ" /etc/localtime' in est


def test_repo_without_an_agent_unit_is_not_an_agent(tmp_path):
    (tmp_path / "README.md").write_text("hi")
    with pytest.raises(NotAnAgent):
        facts(tmp_path)


# --- the agent against real git remotes ---

def test_commits_dockerfile_then_only_when_deployment_changes(tmp_path):
    bare = remote_with(tmp_path, "me/demo", make_agent_repo)
    agent, out = make_agent(tmp_path)
    agent.cfg.watch_public = False

    agent.cycle()
    assert "openssh-client" in show(bare, "Dockerfile") and show(bare, ".dockerignore")
    assert len(out.sent) == 1 and out.sent[0].title == "🐳 Updated .dockerignore, Dockerfile · demo"
    log = subprocess.run(["git", "log", "--format=%an %s", "main"], cwd=bare, capture_output=True, text=True).stdout
    assert log.splitlines()[0] == "Dockerfile agent Update .dockerignore and Dockerfile"

    agent.cycle()  # its own commit moved main: regenerates, finds nothing to change
    push_change(tmp_path, bare, lambda w: (w / "demo_agent" / "__main__.py").write_text("print('v2')\n"))
    agent.cycle()  # code changes reach the image through COPY; the Dockerfile stays as is
    assert len(out.sent) == 1

    push_change(tmp_path, bare, lambda w: (w / "deploy" / "lxc" / "bootstrap-agent.sh").write_text(
        "apt-get install -y -qq python3 openssh-client libpq5 ca-certificates\n", newline="\n"))
    agent.cycle()
    assert "ca-certificates libpq5 openssh-client" in show(bare, "Dockerfile")
    assert len(out.sent) == 2 and "+ && apt-get install -y --no-install-recommends ca-certificates libpq5" \
        in out.sent[1].markdown()


def test_a_new_template_regenerates_unchanged_repos(tmp_path):
    bare = remote_with(tmp_path, "me/demo", make_agent_repo)
    agent, out = make_agent(tmp_path)
    agent.cfg.watch_public = False
    agent.cycle()
    agent.cycle()
    assert len(out.sent) == 1
    agent.cfg.base_image = "python:3.14-slim-trixie"  # e.g. a new BASE_IMAGE, or an upgraded agent
    agent.__init__(agent.cfg, agent.git, agent.state, agent.outbox, agent.clock)
    agent.cycle()
    assert "FROM python:3.14-slim-trixie" in show(bare, "Dockerfile") and len(out.sent) == 2


def test_public_copy_checked_for_drift_after_a_grace_period(tmp_path):
    now = [1000.0]
    bare = remote_with(tmp_path, "me/demo", make_agent_repo)
    agent, out = make_agent(tmp_path, clock=lambda: now[0])
    agent.cfg.watch_public = False
    agent.cycle()  # private gets its Dockerfile

    def mirror(w):  # what the sync publishes: the private tree
        src = tmp_path / "mirror-src"
        shutil.rmtree(src, ignore_errors=True)
        git("clone", "-q", str(bare), str(src), cwd=tmp_path)
        shutil.copytree(src, w, dirs_exist_ok=True, ignore=shutil.ignore_patterns(".git"))

    pub = remote_with(tmp_path, "me/demo-public", mirror)
    agent.cfg.watch_public = True
    sent = len(out.sent)
    agent.cycle()
    assert agent.state["public"] == {} and len(out.sent) == sent  # consistent

    push_change(tmp_path, pub, lambda w: (w / "deploy" / "lxc" / "bootstrap-agent.sh").write_text(
        "apt-get install -y -qq git\n", newline="\n"))  # someone edits the public copy directly
    agent.cycle()
    entry = agent.state["public"]["me/demo-public"]
    assert len(entry["problems"]) == 2 and not entry["alerted"] and len(out.sent) == sent  # still in grace
    now[0] += 20 * 60
    agent.cycle()
    agent.cycle()
    assert len(out.sent) == sent + 1 and "out of step" in out.sent[-1].title  # reported once
    assert "overwritten by the next sync" in out.sent[-1].markdown()


def test_errors_are_reported_once_after_repeated_failures_then_recovery(tmp_path):
    agent, out = make_agent(tmp_path, repos=("me/missing",))
    agent.cfg.watch_public = False
    for _ in range(ERROR_AFTER - 1):
        agent.cycle()
    assert out.sent == [] and agent.state["errors"]["me/missing"]["count"] == ERROR_AFTER - 1
    agent.cycle()
    agent.cycle()
    assert len(out.sent) == 1 and "can't keep the Dockerfile current" in out.sent[0].title
    remote_with(tmp_path, "me/missing", make_agent_repo)
    agent.cycle()
    assert agent.state["errors"] == {} and out.sent[-1].title == "✅ missing is working again"


def test_config_requires_private_repos(monkeypatch):
    monkeypatch.setenv("REPOS", "me/a, me/b")
    cfg = Config.from_env()
    assert cfg.repos == ["me/a", "me/b"] and cfg.public("me/a") == "me/a-public" and cfg.key("me/a").endswith("a")
    monkeypatch.setenv("TIMEZONE", "America/New_York")
    assert Config.from_env().timezone == "America/New_York"
    monkeypatch.setenv("TIMEZONE", "EST5EDT/Nowhere")
    with pytest.raises(SystemExit):
        Config.from_env()
    monkeypatch.delenv("TIMEZONE")
    for bad in ("", "me/a-public", "nope"):
        monkeypatch.setenv("REPOS", bad)
        with pytest.raises(SystemExit):
            Config.from_env()


@pytest.mark.parametrize("workflow", [".github/workflows/deploy.yml", ".public/overlay/.github/workflows/deploy.yml"])
def test_deploy_renders_every_setting_it_is_given(workflow):
    wf = (pathlib.Path(__file__).resolve().parent.parent / workflow).read_text(encoding="utf-8")
    step = wf.split("- name: Render agent.env", 1)[1].split("- name:", 1)[0]
    env_block, run_block = step.split("run: |", 1)
    given = set(re.findall(r"^\s+([A-Z_]+): \$\{\{ (?:vars|secrets)\.", env_block, re.M))
    written = set(re.findall(r"[A-Z_]+", re.search(r"for v in (.*?); do", run_block, re.S).group(1)))
    assert given - written == set(), f"passed to the step but never written to agent.env: {sorted(given - written)}"
