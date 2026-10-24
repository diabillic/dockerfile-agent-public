# Uptime Kuma on a Docker host, deployed with deploy/deploy-app.sh. agent-deploy builds it with --pull
# and a new PATCHED_AT, and the Proxmox janitor's weekly agent-redeploy rebuilds it, so the OS under
# the official image is fully patched every time.
FROM louislam/uptime-kuma:2

ARG DEBIAN_FRONTEND=noninteractive
ARG PATCHED_AT=unknown
ARG REVISION=unknown
ENV TZ=America/New_York
RUN echo "Patching the base OS ($PATCHED_AT)" \
 && apt-get update \
 && apt-get -y full-upgrade \
 && apt-get install -y --no-install-recommends tzdata \
 && apt-get clean && rm -rf /var/lib/apt/lists/*

# The upstream image doesn't declare it; without it the data would be lost on every rebuild.
VOLUME ["/app/data"]
