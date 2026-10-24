#!/usr/bin/env bash
# One-time (re-runnable) provisioning, run from an admin workstation with:
#   - root SSH to the Proxmox host
#   - gh CLI authenticated with admin on this repo and every watched repo
# Creates the dockerfile-agent LXC, registers a runner instance for this repo on the existing
# gh-runner LXC, gives the agent a write deploy key on every watched repository, and sets the
# AGENT_HOST and REPOS variables.
# Env: PVE_HOST (SSH alias or address of the Proxmox host; required),
#      REPOS ("owner/a owner/b": the private agent repositories to keep a Dockerfile in; required.
#             Include this repository to give the agent its own Dockerfile.)
#      GH_REPO, GH_BIN, RUNNER_CTID, AGENT_CTID (default auto), ADMIN_PUBKEY,
#      plus STORAGE / BRIDGE / VLAN / TEMPLATE_STORAGE passed through to create-lxc.sh.
set -euo pipefail

: "${PVE_HOST:?set PVE_HOST to the SSH alias or address of the Proxmox host}"
: "${REPOS:?set REPOS='owner/agent-a owner/agent-b' (private repositories)}"
GH=${GH_BIN:-gh}
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=${GH_REPO:-$(cd "$HERE" && "$GH" repo view --json nameWithOwner --jq .nameWithOwner)}
[[ -n "$REPO" ]] || { echo "set GH_REPO=owner/name" >&2; exit 1; }
RUNNER_NAME=${RUNNER_NAME:-gh-runner}
RUNNER_DIR=${RUNNER_DIR:-/opt/actions-runner-${REPO#*/}}
AGENT_NAME=${AGENT_NAME:-dockerfile-agent}
ADMIN_PUBKEY=${ADMIN_PUBKEY:-$HOME/.ssh/id_ed25519.pub}
PVE=$PVE_HOST
REMOTE=/root/dockerfile-agent-provision

read -r -a repo_list <<<"${REPOS//,/ }"
names=""
for r in "${repo_list[@]}"; do
  [[ "$r" == */* && "$r" != *-public ]] || { echo "REPOS entries must be private owner/name, got $r" >&2; exit 1; }
  names+="${r#*/} "
done

passthru=""
for v in STORAGE BRIDGE VLAN TEMPLATE_STORAGE DISTRO; do
  [[ -n "${!v:-}" ]] && passthru+="$v=${!v} "
done

kv() { sed -n "s/^$1=//p" <<<"$2" | tail -1; }

echo "==> Copying scripts to $PVE:$REMOTE"
ssh "$PVE" "mkdir -p $REMOTE"
scp -q "$HERE/proxmox/create-lxc.sh" "$HERE/lxc/bootstrap-runner.sh" "$HERE/lxc/bootstrap-agent.sh" \
  "$HERE/lxc/dockerfile-agent-install" "$PVE:$REMOTE/"
scp -q "$ADMIN_PUBKEY" "$PVE:$REMOTE/admin.pub"

echo "==> Runner LXC"
out=$(ssh "$PVE" "$passthru MEMORY=2048 CORES=2 DISK=12 bash $REMOTE/create-lxc.sh ${RUNNER_CTID:-auto} $RUNNER_NAME $REMOTE/admin.pub ci")
echo "$out"
RCT=$(kv CTID "$out"); RIP=$(kv IP "$out")

echo "==> Agent LXC"
out=$(ssh "$PVE" "$passthru bash $REMOTE/create-lxc.sh ${AGENT_CTID:-auto} $AGENT_NAME $REMOTE/admin.pub docker")
echo "$out"
ACT=$(kv CTID "$out"); AIP=$(kv IP "$out"); AMAC=$(kv MAC "$out")

echo "==> Registering GitHub runner for $REPO on CT $RCT ($RUNNER_DIR)"
token=$("$GH" api -X POST "repos/$REPO/actions/runners/registration-token" --jq .token)
out=$(ssh "$PVE" "pct push $RCT $REMOTE/bootstrap-runner.sh /root/bootstrap-runner.sh && \
  pct exec $RCT -- env LC_ALL=C.UTF-8 GH_URL=https://github.com/$REPO REG_TOKEN=$token \
  RUNNER_NAME=$RUNNER_NAME RUNNER_DIR=$RUNNER_DIR bash /root/bootstrap-runner.sh")
echo "$out" | grep -v '^DEPLOY_PUBKEY='
DEPLOY_PUBKEY=$(kv DEPLOY_PUBKEY "$out")
[[ -n "$DEPLOY_PUBKEY" ]] || { echo "runner bootstrap did not return a deploy key" >&2; exit 1; }

echo "==> Preparing agent CT $ACT"
out=$(ssh "$PVE" "pct push $ACT $REMOTE/bootstrap-agent.sh /root/bootstrap-agent.sh && \
  pct push $ACT $REMOTE/dockerfile-agent-install /root/dockerfile-agent-install && \
  pct exec $ACT -- env LC_ALL=C.UTF-8 DEPLOY_PUBKEY='$DEPLOY_PUBKEY' INSTALLER=/root/dockerfile-agent-install \
  KEY_NAMES='$names' bash /root/bootstrap-agent.sh")
echo "$out" | grep -v '^KEY '

echo "==> Write deploy keys on the watched repositories"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
for r in "${repo_list[@]}"; do
  pub=$(awk -v n="${r#*/}" '$1=="KEY" && $2==n {print $3" "$4}' <<<"$out")
  [[ -n "$pub" ]] || { echo "no key generated for $r" >&2; exit 1; }
  if "$GH" repo deploy-key list --repo "$r" --json key --jq '.[].key' | grep -qxF "$pub"; then
    echo "  $r: already authorised"
  else
    echo "$pub" > "$tmp/key.pub"
    "$GH" repo deploy-key add "$tmp/key.pub" --repo "$r" --allow-write --title "$AGENT_NAME"
    echo "  $r: added"
  fi
done

echo "==> Trusting agent host key on runner (read via Proxmox, not over the network)"
hostkey=$(ssh "$PVE" "pct exec $ACT -- cat /etc/ssh/ssh_host_ed25519_key.pub" | cut -d' ' -f1,2)
ssh "$PVE" "pct exec $RCT -- runuser -u runner -- sh -c \"grep -v '^$AIP ' ~/.ssh/known_hosts 2>/dev/null > ~/.ssh/kh.tmp; echo '$AIP $hostkey' >> ~/.ssh/kh.tmp; mv ~/.ssh/kh.tmp ~/.ssh/known_hosts\""

echo "==> Setting repo variables AGENT_HOST=$AIP and REPOS"
"$GH" variable set AGENT_HOST --repo "$REPO" --body "$AIP"
"$GH" variable set REPOS --repo "$REPO" --body "$(tr ' ' ',' <<<"${repo_list[*]}")"

cat <<EOF

Done.
  Runner: CT $RCT  $RUNNER_NAME  $RIP  (instance $RUNNER_DIR)
  Agent:  CT $ACT  $AGENT_NAME  $AIP  MAC $AMAC
EOF
