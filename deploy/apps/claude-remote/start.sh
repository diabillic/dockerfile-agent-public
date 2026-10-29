#!/bin/bash
# Keeps `claude remote-control` running in the tmux session "rc". Before the claude.ai login it
# exits and is retried every 30 s, so the container stays up for `claude auth login`.
set -u
mkdir -p "$HOME/homelab" && cd "$HOME/homelab" || exit 1

# The mounted MCP servers replace same-named ones in ~/.claude.json (user scope); others are kept
servers=/etc/claude-remote/mcp.json
if [[ -r "$servers" ]]; then
  [[ -s ~/.claude.json ]] || echo '{}' > ~/.claude.json
  tmp=$(mktemp ~/.claude.json.XXXXXX)
  if jq --slurpfile m "$servers" '.mcpServers = ((.mcpServers // {}) + $m[0].mcpServers)' ~/.claude.json > "$tmp"; then
    chmod 600 "$tmp" && mv "$tmp" ~/.claude.json
    echo "MCP servers: $(jq -r '.mcpServers | keys | join(", ")' "$servers")"
  else
    rm -f "$tmp"; echo "could not merge $servers; MCP servers unchanged" >&2
  fi
fi

tmux new-session -d -s rc -x 160 -y 48 "while true; do
  claude remote-control --name '${RC_NAME:-homelab}' --spawn same-dir --permission-mode '${RC_PERMISSION_MODE:-default}'
  echo 'remote-control exited; restarting in 30 s'; sleep 30
done"
echo "Remote Control running in tmux session rc (docker exec -it <container> tmux attach -t rc)"

# docker stop signals only this script: stop the server with Ctrl-C, as a person would, so it signs
# off at claude.ai instead of being killed and leaving a stale environment there
stop() {
  tmux send-keys -t rc C-c 2>/dev/null
  for _ in $(seq 15); do pgrep -x claude >/dev/null || break; sleep 1; done
  tmux capture-pane -p -t rc 2>/dev/null | sed '/^\s*$/d' | tail -3
  tmux kill-server 2>/dev/null
  exit 0
}
trap stop TERM INT

# Docker restarts the container if the tmux session ever goes away
while tmux has-session -t rc 2>/dev/null; do sleep 30 & wait $!; done
echo "tmux session rc ended" >&2
exit 1
