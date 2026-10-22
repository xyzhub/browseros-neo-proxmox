#!/usr/bin/env bash
# BrowserOS neo — standalone Proxmox LXC installer
# Run as root on the Proxmox VE host. Creates a Debian LXC, runs the official
# BrowserOS neo image (ghcr.io/browseros-ai/neo) in Docker inside it, and puts
# Caddy in front so the viewer and the MCP server are reachable from your LAN
# (and optionally your tailnet) behind credentials.
# Source: https://github.com/browseros-ai/BrowserOS/tree/main/packages/browseros/docker/neo
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/xyzhub/browseros-neo-proxmox/main/browseros-neo-lxc.sh)"
#
#   LXC :6080  Caddy (basic auth)    → 127.0.0.1:16080 → neo noVNC viewer
#   LXC :9010  Caddy (bearer token)  → 127.0.0.1:19010 → neo MCP server (+ /v1 API)
#
# Caddy also rewrites the Host header to loopback: Neo's MCP server only accepts
# Host: localhost / 127.0.0.1 / ::1 (DNS-rebinding guard) and has no setting to
# extend that list, so without the rewrite every non-local client gets a 403.
set -euo pipefail

# ----- configuration (override via env) -----
CTID="${CTID:-}"                  # empty = next free ID, resolved after the host checks below
CT_HOSTNAME="${CT_HOSTNAME:-neo}" # not HOSTNAME: bash presets that to the host's name
DISK_GB="${DISK_GB:-16}"
CORES="${CORES:-2}"
RAM_MB="${RAM_MB:-4096}"
BRIDGE="${BRIDGE:-vmbr0}"
STORAGE="${STORAGE:-local-lvm}"
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"
OS_TEMPLATE="${OS_TEMPLATE:-debian-13-standard}"
NEO_VERSION="${NEO_VERSION:-latest}" # image tag; :latest is the tag published for amd64 + arm64
NEO_MODE="${NEO_MODE:-hosted}"       # hosted = browser tools only; desktop = full BrowserOS tool set
NEO_SCREEN="${NEO_SCREEN:-1600x1000}"
TS_AUTHKEY="${TS_AUTHKEY:-}" # optional: join the LXC to your tailnet and expose both ports over HTTPS
VIEWER_PORT=6080
MCP_PORT=9010

# ----- guard rails -----
[[ $EUID -eq 0 ]] || {
  echo "Run as root on the Proxmox host." >&2
  exit 1
}
if ! command -v pct >/dev/null || ! command -v pveam >/dev/null; then
  echo "pct/pveam not found — run on a Proxmox VE host." >&2
  exit 1
fi
case "$(dpkg --print-architecture)" in
  amd64 | arm64) ;;
  *)
    echo "The neo image is published for amd64 and arm64 only." >&2
    exit 1
    ;;
esac
CTID="${CTID:-$(pvesh get /cluster/nextid)}"
if pct status "$CTID" >/dev/null 2>&1; then
  echo "CTID $CTID already exists. Set CTID=<free id>." >&2
  exit 1
fi
trap 'echo "Failed. Container $CTID may exist; inspect with: pct enter '"$CTID"'  /  remove with: pct stop '"$CTID"'; pct destroy '"$CTID"'" >&2' ERR

# ----- ensure template, create + start -----
echo "==> Ensuring OS template"
pveam update >/dev/null
TEMPLATE="$(pveam available --section system | awk -v t="$OS_TEMPLATE" '$0 ~ t {print $2}' | sort -V | tail -n1)"
[[ -n "$TEMPLATE" ]] || {
  echo "No template matching $OS_TEMPLATE" >&2
  exit 1
}
pveam list "$TEMPLATE_STORAGE" 2>/dev/null | grep -q "$TEMPLATE" || pveam download "$TEMPLATE_STORAGE" "$TEMPLATE"

echo "==> Creating LXC $CTID ($CT_HOSTNAME)"
# nesting + keyctl: required for Docker inside an unprivileged LXC.
pct create "$CTID" "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}" \
  --hostname "$CT_HOSTNAME" \
  --cores "$CORES" --memory "$RAM_MB" --swap 1024 \
  --rootfs "${STORAGE}:${DISK_GB}" \
  --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp" \
  --unprivileged 1 \
  --features nesting=1,keyctl=1 \
  --onboot 1

if [[ -n "$TS_AUTHKEY" ]]; then
  # Tailscale needs the TUN device passed into the container.
  cat >>"/etc/pve/lxc/${CTID}.conf" <<'TUN'
lxc.cgroup2.devices.allow: c 10:200 rwm
lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file
TUN
fi

pct start "$CTID"

echo "==> Waiting for network"
for _ in $(seq 1 30); do
  pct exec "$CTID" -- bash -c "getent hosts deb.debian.org" >/dev/null 2>&1 && break
  sleep 2
done

# ----- install inside the container -----
echo "==> Installing BrowserOS neo (pulls a ~1 GB image; this can take a while)"
pct exec "$CTID" -- env \
  NEO_VERSION="$NEO_VERSION" NEO_MODE="$NEO_MODE" NEO_SCREEN="$NEO_SCREEN" \
  TS_AUTHKEY="$TS_AUTHKEY" CT_HOSTNAME="$CT_HOSTNAME" \
  VIEWER_PORT="$VIEWER_PORT" MCP_PORT="$MCP_PORT" \
  bash -s <<'INSTALL'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update && apt-get -y upgrade
apt-get install -y curl ca-certificates gnupg openssl jq caddy

# --- runtime: Docker CE + compose plugin ---
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  >/etc/apt/sources.list.d/docker.list
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
systemctl enable -q --now docker

# --- neo (upstream compose, with ports moved behind Caddy) ---
mkdir -p /opt/neo/data
chown 1000:1000 /opt/neo/data
cat >/opt/neo/.env <<ENV
NEO_VERSION=${NEO_VERSION}
BROWSERCLAW_MODE=${NEO_MODE}
NEO_SCREEN=${NEO_SCREEN}
ENV
cat >/opt/neo/compose.yaml <<'COMPOSE'
# Based on packages/browseros/docker/neo/compose.yaml. Both ports stay on
# loopback: neither asks for a password, so Caddy fronts them with auth.
services:
  neo:
    image: ghcr.io/browseros-ai/neo:${NEO_VERSION:-latest}
    init: false # the image runs tini itself
    shm_size: 1g
    hostname: neo
    stop_grace_period: 20s
    ports:
      - "127.0.0.1:16080:6080"
      - "127.0.0.1:19010:9010"
    volumes:
      - "/opt/neo/data:/data"
    environment:
      PUID: 1000
      PGID: 1000
      NEO_SCREEN: ${NEO_SCREEN:-1600x1000}
      BROWSERCLAW_MODE: ${BROWSERCLAW_MODE:-hosted}
      NEO_SANDBOX: "false"
    restart: unless-stopped
COMPOSE
cd /opt/neo || exit 1
docker compose pull
docker compose up -d --wait --wait-timeout 300

# --- auth + Host-rewriting reverse proxy ---
VIEWER_PASS="$(openssl rand -base64 18 | tr -dc 'a-zA-Z0-9')"
MCP_TOKEN="$(openssl rand -hex 32)"
VIEWER_HASH="$(caddy hash-password --plaintext "$VIEWER_PASS")"
cat >/etc/caddy/Caddyfile <<CADDY
{
	auto_https off
	admin off
}

# noVNC viewer: full control of Neo's screen, so it needs a password.
:${VIEWER_PORT} {
	basicauth {
		neo ${VIEWER_HASH}
	}
	reverse_proxy 127.0.0.1:16080
}

# MCP server and /v1 API: bearer token, then rewrite Host to loopback so
# Neo's DNS-rebinding check accepts the request.
:${MCP_PORT} {
	@authorized header Authorization "Bearer ${MCP_TOKEN}"
	handle @authorized {
		reverse_proxy 127.0.0.1:19010 {
			header_up Host 127.0.0.1:9010
			header_up -Origin
			flush_interval -1
		}
	}
	handle {
		respond "Unauthorized" 401
	}
}
CADDY
chmod 640 /etc/caddy/Caddyfile
chown root:caddy /etc/caddy/Caddyfile
caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
systemctl enable -q caddy
systemctl restart caddy

# --- optional: tailnet access over HTTPS ---
TS_LINE=""
if [[ -n "$TS_AUTHKEY" ]]; then
  curl -fsSL https://tailscale.com/install.sh | sh
  tailscale up --authkey="$TS_AUTHKEY" --hostname="$CT_HOSTNAME"
  tailscale serve --bg --https=443 "http://127.0.0.1:${MCP_PORT}"
  tailscale serve --bg --https=8443 "http://127.0.0.1:${VIEWER_PORT}"
  TS_NAME="$(tailscale status --json | jq -r '.Self.DNSName' | sed 's/\.$//')"
  TS_LINE="Tailnet MCP:    https://${TS_NAME}/mcp
Tailnet viewer: https://${TS_NAME}:8443"
fi

# --- update helper ---
cat >/usr/local/bin/neo-update <<'UPDATE'
#!/usr/bin/env bash
set -euo pipefail
cd /opt/neo || exit 1
docker compose pull
docker compose up -d --wait --wait-timeout 300
docker image prune -f
UPDATE
chmod +x /usr/local/bin/neo-update

IP="$(hostname -I | awk '{print $1}')"
cat >/root/neo.creds <<CREDS
Viewer:        http://${IP}:${VIEWER_PORT}   (user: neo  password: ${VIEWER_PASS})
MCP:           http://${IP}:${MCP_PORT}/mcp
MCP token:     ${MCP_TOKEN}
${TS_LINE}

Claude Code:
  claude mcp add --transport http neo <MCP URL> --header "Authorization: Bearer ${MCP_TOKEN}"
CREDS
chmod 600 /root/neo.creds

apt-get -y autoremove && apt-get -y autoclean
INSTALL

# ----- report -----
trap - ERR
echo "==> Done. CTID=$CTID"
pct exec "$CTID" -- cat /root/neo.creds
echo
echo "Open the viewer and sign in to your sites once; logins persist in /opt/neo/data."
echo "Update later with: pct exec $CTID -- neo-update"
