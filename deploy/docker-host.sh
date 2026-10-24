#!/usr/bin/env bash
# Prepare a Docker VM (e.g. from the community-scripts Docker VM script) to receive agent
# deploys, and let the given runners deploy to it. Re-runnable. Run from an admin workstation
# with root SSH to the Proxmox nodes; the VM must accept the same admin key (cloud-init).
#   VM=<node>:<vmid> RUNNERS="<node>:<runner ctid> ..." [ADMIN_KEY=~/.ssh/key] [DOCKER_API_ALLOW=<ip,...>] [TIMEZONE=<zone>] deploy/docker-host.sh
# DOCKER_API_ALLOW opens the unauthenticated Docker API on tcp/2375 to those addresses only (e.g. a
# Dockhand or Portainer host); leaving it unset removes it.
# JANITOR_PUBKEY=<file> JANITOR_FROM=<ip[,cidr]> lets that key (the Proxmox janitor's) start a
# rebuild of every agent on this host and read its status, from those addresses only. Pass the
# Docker bridge range (172.16.0.0/12) too when the janitor runs on this same host.
# The VM's address and SSH host key are read through the QEMU guest agent, so nothing is
# trusted on first use. Prints DOCKER_HOST=<address> at the end: use it as AGENT_HOST in the
# repositories that deploy there.
set -euo pipefail
: "${VM:?set VM=<node>:<vmid>}" "${RUNNERS:?set RUNNERS=\"<node>:<ctid> ...\" (runner LXCs allowed to deploy)}"
HERE=$(cd "$(dirname "$0")" && pwd)
node=${VM%%:*}; vmid=${VM#*:}
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# Run a command in the VM through the guest agent and print its stdout.
gexec() {
  ssh "$node" "qm guest exec $vmid --timeout 30 -- $* | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.stdout.write(d.get(\"out-data\", \"\")); sys.exit(d.get(\"exitcode\", 1))'"
}

ip=$(ssh "$node" python3 - "$vmid" <<'EOF'
import json, subprocess, sys
out = subprocess.run(["qm", "guest", "cmd", sys.argv[1], "network-get-interfaces"], capture_output=True, text=True).stdout
for i in json.loads(out or "[]"):
    if i["name"] == "lo" or i["name"].startswith(("docker", "br-", "veth")):
        continue
    for a in i.get("ip-addresses", []):
        if a["ip-address-type"] == "ipv4":
            print(a["ip-address"]); sys.exit()
EOF
)
[[ -n "$ip" ]] || { echo "VM $vmid reports no IPv4 address (is the guest agent running?)" >&2; exit 1; }
hostkey=$(gexec cat /etc/ssh/ssh_host_ed25519_key.pub | cut -d' ' -f1,2)
[[ "$hostkey" == ssh-ed25519\ * ]] || { echo "couldn't read the VM's host key" >&2; exit 1; }
echo "$ip $hostkey" > "$tmp/known_hosts"
opts=(-o UserKnownHostsFile="$tmp/known_hosts" -o StrictHostKeyChecking=yes)
[[ -n "${ADMIN_KEY:-}" ]] && opts+=(-i "$ADMIN_KEY" -o IdentitiesOnly=yes)
vm_ssh() { ssh "${opts[@]}" "root@$ip" "$@"; }
vm_scp() { scp -q "${opts[@]}" "$@"; }

echo "==> Runner keys allowed to deploy to $ip"
: > "$tmp/runner_keys"
for r in $RUNNERS; do
  ssh "${r%%:*}" "pct exec ${r#*:} -- cat /home/runner/.ssh/id_ed25519.pub" >> "$tmp/runner_keys"
  echo "  ${r}"
done

if [[ -n "${JANITOR_PUBKEY:-}" ]]; then
  [[ "${JANITOR_FROM:-}" =~ ^[0-9./,]+$ ]] || { echo "JANITOR_FROM must be IPv4 addresses/CIDRs" >&2; exit 1; }
  echo "command=\"/usr/local/sbin/agent-redeploy-ssh\",restrict,from=\"$JANITOR_FROM\" $(cut -d' ' -f1-3 "$JANITOR_PUBKEY")" >> "$tmp/runner_keys"
  echo "  janitor (from $JANITOR_FROM)"
fi

echo "==> Bootstrapping VM $vmid ($ip)"
vm_scp "$HERE/docker-host/agent-deploy" "$HERE/docker-host/agent-redeploy" "$HERE/docker-host/agent-redeploy-ssh" \
  "$HERE/docker-host/bootstrap-docker-host.sh" "$tmp/runner_keys" "root@$ip:/root/"
vm_ssh "DOCKER_API_ALLOW='${DOCKER_API_ALLOW:-}' TIMEZONE='${TIMEZONE:-}' bash /root/bootstrap-docker-host.sh /root/agent-deploy /root/runner_keys && rm -f /root/agent-deploy /root/agent-redeploy /root/agent-redeploy-ssh /root/bootstrap-docker-host.sh /root/runner_keys"

echo "==> Pinning the VM's host key on the runners"
for r in $RUNNERS; do
  ssh "${r%%:*}" "pct exec ${r#*:} -- runuser -u runner -- sh -c \"grep -v '^$ip ' ~/.ssh/known_hosts 2>/dev/null > ~/.ssh/kh.tmp; echo '$ip $hostkey' >> ~/.ssh/kh.tmp; mv ~/.ssh/kh.tmp ~/.ssh/known_hosts\""
done

echo "DOCKER_HOST=$ip"
