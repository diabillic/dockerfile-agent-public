#!/usr/bin/env bash
# Runs INSIDE the agent LXC as root. Prepares it to receive deploys from the runner and gives
# the service account one SSH deploy key per watched repository (GitHub allows a deploy key on
# one repository only).
# Env: DEPLOY_PUBKEY (runner's deploy key), INSTALLER (path to pushed dockerfile-agent-install),
#      KEY_NAMES (repository names, space separated)
# Prints "KEY <name> <public key>" for each repository.
#
# The `deploy` user can only stage files and run the root-owned installer via sudo;
# the installer writes the systemd unit itself, so a deploy can't change what runs as root.
set -euo pipefail
: "${DEPLOY_PUBKEY:?}" "${INSTALLER:?}" "${KEY_NAMES:?}"

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq python3 python3-venv rsync sudo openssh-server openssh-client git ca-certificates >/dev/null
systemctl enable --now ssh >/dev/null

id dockerfile-agent >/dev/null 2>&1 || useradd --system --home-dir /var/lib/dockerfile-agent --shell /usr/sbin/nologin dockerfile-agent
id deploy >/dev/null 2>&1 || useradd --create-home --shell /bin/bash deploy

install -d -m 700 -o deploy -g deploy /home/deploy/.ssh /home/deploy/staging
echo "$DEPLOY_PUBKEY" > /home/deploy/.ssh/authorized_keys
chown deploy:deploy /home/deploy/.ssh/authorized_keys
chmod 600 /home/deploy/.ssh/authorized_keys

# Deploy keys with write access to the watched repositories. They never leave this box.
install -d -m 755 -o dockerfile-agent -g dockerfile-agent /var/lib/dockerfile-agent
install -d -m 700 -o dockerfile-agent -g dockerfile-agent /var/lib/dockerfile-agent/keys
for name in $KEY_NAMES; do
  key=/var/lib/dockerfile-agent/keys/$name
  [[ -f "$key" ]] || runuser -u dockerfile-agent -- ssh-keygen -q -t ed25519 -N "" -C "dockerfile-agent@$name" -f "$key"
done

install -d -m 755 /opt/dockerfile-agent
install -d -m 750 -g dockerfile-agent /etc/dockerfile-agent
install -m 750 -o root -g root "$INSTALLER" /usr/local/sbin/dockerfile-agent-install

echo 'deploy ALL=(root) NOPASSWD: /usr/local/sbin/dockerfile-agent-install' > /etc/sudoers.d/dockerfile-agent-deploy
chmod 440 /etc/sudoers.d/dockerfile-agent-deploy
visudo -cf /etc/sudoers.d/dockerfile-agent-deploy >/dev/null

echo "agent LXC ready"
for name in $KEY_NAMES; do
  echo "KEY $name $(cut -d' ' -f1,2 /var/lib/dockerfile-agent/keys/$name.pub)"
done
