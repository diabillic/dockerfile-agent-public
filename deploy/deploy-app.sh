#!/usr/bin/env bash
# Deploy a third-party app from deploy/apps/<app>/ to a Docker host through agent-deploy, exactly like
# an agent: built fully patched (--pull, apt full-upgrade), rolled back if it doesn't stay up, and
# rebuilt every week by agent-redeploy. Re-run it after changing the app's Dockerfile or env.
#   APP=uptime-kuma HOST=192.0.2.21 PUBLISH=3001:3001 [PRIORITY=high] [ENV_FILE=app.env] \
#     [ADMIN_KEY=~/.ssh/id_ed25519] deploy/deploy-app.sh
# The app's data lives in the volume <app>-data (from the image's VOLUME).
set -euo pipefail
: "${APP:?set APP=<directory under deploy/apps>}" "${HOST:?set HOST=<docker host address>}"
HERE=$(cd "$(dirname "$0")" && pwd)
ctx="$HERE/apps/$APP"
[[ -f "$ctx/Dockerfile" ]] || { echo "no $ctx/Dockerfile" >&2; exit 1; }
[[ "$APP" =~ ^[a-z][a-z0-9-]{1,40}$ ]] || { echo "APP must be lowercase letters, digits and dashes" >&2; exit 1; }
opts=()
[[ -n "${ADMIN_KEY:-}" ]] && opts+=(-i "$ADMIN_KEY" -o IdentitiesOnly=yes)

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/context"
cp -r "$ctx/." "$tmp/context/"
if [[ -n "${ENV_FILE:-}" ]]; then cp "$ENV_FILE" "$tmp/agent.env"; else : > "$tmp/agent.env"; fi
rev=$(cat "$tmp/context/"* | sha1sum | cut -c1-40)  # the app's "revision" is its build context
printf 'REVISION=%s\nPUBLISH=%s\nPRIORITY=%s-priority\n' "$rev" "${PUBLISH:-}" "${PRIORITY:-high}" > "$tmp/deploy.env"

ssh "${opts[@]}" "root@$HOST" "rm -rf /home/deploy/staging/$APP && install -d -m 755 -o deploy -g deploy /home/deploy/staging/$APP"
tar -C "$tmp" -cf - . | ssh "${opts[@]}" "root@$HOST" "tar -C /home/deploy/staging/$APP -xf - && chown -R deploy:deploy /home/deploy/staging/$APP"
ssh "${opts[@]}" "root@$HOST" "/usr/local/sbin/agent-deploy $APP"
