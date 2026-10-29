# Claude Code Remote Control (code.claude.com/docs/en/remote-control) on a Docker host, deployed with
# deploy/deploy-app.sh and rebuilt weekly like everything else: each build installs the newest Claude
# Code and patches the OS. `claude remote-control` runs in a tmux session (its one-time questions need
# a terminal) and is restarted when it exits. Outbound only: nothing is published.
# One-time setup after the first deploy (claude.ai login; API keys and setup-token can't do this):
#   docker exec -it claude-remote claude auth login
#   docker exec -it claude-remote tmux attach -t rc     (answer its questions, then detach: Ctrl-b d)
# MCP servers come from a root-made file on the host, owned by uid 1000 and mode 400, merged into
# ~/.claude.json at every start, so tokens stay out of the image and the environment:
#   {"mcpServers": {"<name>": {"type": "http", "url": "...", "headers": {"Authorization": "Bearer ..."}}}}
# EXTRA, one per line:
#   mount=/etc/agents/claude-remote/mcp.json:/etc/claude-remote/mcp.json:ro
#   mount=/etc/agents/claude-remote/ca.pem:/etc/claude-remote/ca.pem:ro   (pinned self-signed certs)
#   hostname=homelab   (claude.ai shows the machine's hostname, otherwise the container id)
# claude.ai names the environment after the working folder, ~/homelab.
# Optional ENV_FILE: RC_NAME (session title, default homelab), RC_PERMISSION_MODE (default: ask).
FROM debian:trixie-slim

ARG PATCHED_AT=unknown
ARG REVISION=unknown
RUN echo "Patching the base OS ($PATCHED_AT)" && apt-get update && apt-get -y full-upgrade \
 && apt-get install -y --no-install-recommends ca-certificates curl git jq less procps ripgrep tmux tzdata \
 && rm -rf /var/lib/apt/lists/* \
 && useradd -m -u 1000 -s /bin/bash claude && install -d -o claude -g claude /home/claude/homelab
# The installer puts claude under ~/.local; the binary is copied out so it isn't hidden by the home
# volume, and the auto-updater is off: the weekly rebuild brings the newest version.
RUN curl -fsSL https://claude.ai/install.sh | HOME=/tmp/cc bash \
 && install -m 755 "$(readlink -f /tmp/cc/.local/bin/claude)" /usr/local/bin/claude && rm -rf /tmp/cc \
 && claude --version
COPY --chmod=755 start.sh /usr/local/bin/claude-remote

ENV TZ=America/New_York LANG=C.UTF-8 TERM=xterm-256color HOME=/home/claude DISABLE_AUTOUPDATER=1 \
    NODE_EXTRA_CA_CERTS=/etc/claude-remote/ca.pem
USER claude
WORKDIR /home/claude/homelab
# Login, settings, sessions and the working folder
VOLUME /home/claude

HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=4 CMD pgrep -x claude >/dev/null
CMD ["/usr/local/bin/claude-remote"]
