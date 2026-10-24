#!/usr/bin/env bash
# Runs ON a Docker host (e.g. a community-scripts Docker VM) as root. Re-runnable.
#   bootstrap-docker-host.sh <agent-deploy file> <authorized keys file>
# Patches the OS and turns on unattended security upgrades (never reboots by itself), creates
# the `deploy` user that runners SSH in as, and lets it run only /usr/local/sbin/agent-deploy and
# /usr/local/sbin/agent-redeploy (start/status). agent-redeploy and agent-redeploy-ssh must sit
# next to the agent-deploy file. The keys file holds the runners' keys and, optionally, a
# janitor line forced to agent-redeploy-ssh; without one, an existing janitor line is kept.
set -euo pipefail
DEPLOYER=${1:?agent-deploy file}; RUNNER_KEYS=${2:?runner public keys file}

if [[ -n "${TIMEZONE:-}" ]]; then  # e.g. America/New_York; containers keep their own (UTC)
  [[ -f "/usr/share/zoneinfo/$TIMEZONE" ]] || { echo "unknown TIMEZONE $TIMEZONE" >&2; exit 1; }
  timedatectl set-timezone "$TIMEZONE"
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get -y -qq -o Dpkg::Options::=--force-confold full-upgrade >/dev/null
apt-get install -y -qq unattended-upgrades apt-listchanges needrestart rsync sudo >/dev/null
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
cat > /etc/apt/apt.conf.d/52homelab-unattended <<'EOF'
// Security updates only, no automatic reboots: the patch agent reports when one is needed.
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
EOF
systemctl enable --now unattended-upgrades >/dev/null 2>&1

# Container logs are capped per container by agent-deploy; cap anything else started by hand too.
if [[ ! -s /etc/docker/daemon.json ]] || ! grep -q max-size /etc/docker/daemon.json; then
  python3 - <<'EOF'
import json, os
p = "/etc/docker/daemon.json"
cfg = json.load(open(p)) if os.path.exists(p) and os.path.getsize(p) else {}
cfg.setdefault("log-driver", "json-file")
cfg.setdefault("log-opts", {}).update({"max-size": "10m", "max-file": "3"})
json.dump(cfg, open(p, "w"), indent=2)
EOF
  systemctl restart docker
fi

# Optional: the Docker API on TCP 2375 for a remote manager such as Dockhand or Portainer, firewalled
# to DOCKER_API_ALLOW (comma-separated IPv4 addresses or CIDRs). It has no authentication, so
# whoever can reach it is root on this host. Unset removes it again.
dropin=/etc/systemd/system/docker.service.d/tcp-api.conf
fwunit=/etc/systemd/system/docker-api-firewall.service
if [[ -n "${DOCKER_API_ALLOW:-}" ]]; then
  [[ "$DOCKER_API_ALLOW" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}(/[0-9]{1,2})?(,[0-9]{1,3}(\.[0-9]{1,3}){3}(/[0-9]{1,2})?)*$ ]] \
    || { echo "DOCKER_API_ALLOW must be IPv4 addresses or CIDRs, comma separated" >&2; exit 1; }
  apt-get install -y -qq nftables >/dev/null
  install -d /etc/homelab /etc/systemd/system/docker.service.d
  # Its own table, so Docker's rules and any other firewall are left alone. The first two lines
  # make reloading idempotent.
  cat > /etc/homelab/docker-api.nft <<EOF
table inet docker_api
delete table inet docker_api
table inet docker_api {
  chain input {
    type filter hook input priority -10; policy accept;
    tcp dport 2375 ip saddr { ${DOCKER_API_ALLOW//,/, } } accept
    tcp dport 2375 drop
  }
}
EOF
  cat > "$fwunit" <<'EOF'
[Unit]
Description=Allow the Docker API (TCP 2375) only from the configured addresses
DefaultDependencies=no
Before=docker.service network-pre.target
Wants=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/nft -f /etc/homelab/docker-api.nft

[Install]
WantedBy=multi-user.target
EOF
  # dockerd only listens on TCP once the firewall is in place.
  cat > "$dropin" <<'EOF'
[Unit]
Requires=docker-api-firewall.service
After=docker-api-firewall.service

[Service]
ExecStart=
ExecStart=/usr/bin/dockerd -H fd:// -H tcp://0.0.0.0:2375 --tls=false --containerd=/run/containerd/containerd.sock
EOF
  systemctl daemon-reload
  systemctl enable docker-api-firewall.service >/dev/null 2>&1
  systemctl restart docker-api-firewall.service
  systemctl restart docker
  echo "Docker API on tcp/2375, allowed from: $DOCKER_API_ALLOW"
elif [[ -f "$dropin" ]]; then
  rm -f "$dropin"
  systemctl disable --now docker-api-firewall.service >/dev/null 2>&1 || true
  rm -f "$fwunit" /etc/homelab/docker-api.nft
  nft delete table inet docker_api 2>/dev/null || true
  systemctl daemon-reload
  systemctl restart docker
  echo "Docker API on tcp/2375 removed"
fi

id deploy >/dev/null 2>&1 || useradd --create-home --shell /bin/bash deploy
install -d -m 700 -o deploy -g deploy /home/deploy/.ssh /home/deploy/staging
keys=$(mktemp)
cat "$RUNNER_KEYS" > "$keys"
if ! grep -q 'agent-redeploy-ssh' "$RUNNER_KEYS"; then  # keep the janitor's line across re-runs
  grep -s 'command="/usr/local/sbin/agent-redeploy-ssh"' /home/deploy/.ssh/authorized_keys >> "$keys" || true
fi
install -m 600 -o deploy -g deploy "$keys" /home/deploy/.ssh/authorized_keys
rm -f "$keys"

here=$(dirname "$DEPLOYER")
install -m 750 -o root -g root "$DEPLOYER" /usr/local/sbin/agent-deploy
install -m 750 -o root -g root "$here/agent-redeploy" /usr/local/sbin/agent-redeploy
install -m 755 -o root -g root "$here/agent-redeploy-ssh" /usr/local/sbin/agent-redeploy-ssh
echo 'deploy ALL=(root) NOPASSWD: /usr/local/sbin/agent-deploy, /usr/local/sbin/agent-redeploy start, /usr/local/sbin/agent-redeploy status' \
  > /etc/sudoers.d/agent-deploy
chmod 440 /etc/sudoers.d/agent-deploy
visudo -cf /etc/sudoers.d/agent-deploy >/dev/null

echo "docker host $(hostname) ready: $(docker --version)"
