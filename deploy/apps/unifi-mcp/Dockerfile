# UniFi MCP server (github.com/enuno/unifi-mcp-server) on a Docker host, deployed with
# deploy/deploy-app.sh and rebuilt weekly like everything else: --pull picks up 0.6.x releases and
# the apk layer patches the OS. Every read-only tool, Streamable HTTP on :3000/mcp; a client that
# needs fewer (Hermes) filters on its side.
# Site-specific settings go in ENV_FILE, never here:
#   UNIFI_LOCAL_HOST=<the name on the console's certificate, e.g. unifi.local>
#   UNIFI_LOCAL_CA_FILE=/app/config/console.pem
# The secrets stay out of the container's environment (docker inspect, the socket proxy, /proc):
# they go in a root-made file on the host, owned by uid 1000 (the image's user) and mode 400, that
# upstream's settings read as /app/.env:
#   UNIFI_API_KEY=<key from the console's Settings > Control Plane > Integrations>
#   MCP_AUTH_TOKEN=viewer:<token>,viewer:<another>   (one per client, each openssl rand -hex 32;
#                                                      clients send "Authorization: Bearer <token>")
# EXTRA, one per line: host=unifi.local:<console address>
#   mount=/etc/agents/unifi-mcp/console.pem:/app/config/console.pem:ro   (the pinned certificate)
#   mount=/etc/agents/unifi-mcp/secrets.env:/app/.env:ro
FROM ghcr.io/enuno/unifi-mcp-server:0.6

ARG PATCHED_AT=unknown
ARG REVISION=unknown
USER root
# A UniFi console's self-signed certificate has no Basic Constraints, which Python 3.13's strict
# X.509 mode demands of a trust anchor. The pinned certificate is still the only one trusted and the
# hostname is still checked; only the strict-mode extras are dropped. The grep fails the build if
# upstream changes the line.
RUN echo "Patching the base OS ($PATCHED_AT)" && apk upgrade --no-cache && apk add --no-cache tzdata \
 && sed -i 's|^    return ssl.create_default_context(cafile=ca_file)$|    ctx = ssl.create_default_context(cafile=ca_file)\n    ctx.verify_flags \&= ~ssl.VERIFY_X509_STRICT\n    return ctx|' \
      /app/src/api/tls.py \
 && grep -q '^    ctx.verify_flags &= ~ssl.VERIFY_X509_STRICT$' /app/src/api/tls.py
USER mcp

ENV TZ=America/New_York UNIFI_API_TYPE=local UNIFI_READ_ONLY=true UNIFI_STDIO_ROLE=viewer \
    MCP_SERVER_TRANSPORT=streamable_http MCP_SERVER_HOST=0.0.0.0 MCP_SERVER_PORT=3000

# Upstream's check only loads the settings; this one asks the running server.
HEALTHCHECK --interval=30s --timeout=10s --start-period=20s --retries=5 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:3000/healthz', timeout=5)"
