# A read-only view of this host's Docker API for Uptime Kuma's container monitors: container
# listing and inspection only (GET /containers/...), no changes (POST=0). Deployed with
# deploy/deploy-app.sh with EXTRA="mount=/var/run/docker.sock:/var/run/docker.sock:ro" (plus a
# network or a firewalled PUBLISH), and rebuilt weekly like everything else. Inspection includes
# containers' environment, so keep its reach to the monitoring host only.
FROM tecnativa/docker-socket-proxy:latest

ARG PATCHED_AT=unknown
ARG REVISION=unknown
ENV CONTAINERS=1 POST=0 TZ=America/New_York
RUN echo "Patching the base OS ($PATCHED_AT)" && apk upgrade --no-cache && apk add --no-cache tzdata
