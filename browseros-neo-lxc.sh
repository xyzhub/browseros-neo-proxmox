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
NEO_SANDBOX="${NEO_SANDBOX:-false}" # true = Chromium sandbox on (relaxes Docker seccomp/AppArmor for neo); upstream default is off
TAILSCALE="${TAILSCALE:-}"          # yes = join your tailnet (login URL), no = skip, empty = ask
TS_AUTHKEY="${TS_AUTHKEY:-}"        # join unattended with this auth key instead of the login URL
VIEWER_PORT=6080
MCP_PORT=9010
SCRIPT_URL="https://raw.githubusercontent.com/xyzhub/browseros-neo-proxmox/main/browseros-neo-lxc.sh"

# ----- update mode: the same script run inside an existing neo LXC -----
# Like community-scripts: no Proxmox tools + an existing install means "update",
# so `update` in the container console (or this one-liner there) upgrades in place.
update_neo() {
  [[ $EUID -eq 0 ]] || {
    echo "Run as root inside the neo container." >&2
    exit 1
  }
  local log=/var/log/neo-update.log
  trap 'echo "Failed. Last lines of '"$log"':" >&2; tail -n 25 '"$log"' >&2' ERR
  echo "==> Updating OS packages$(command -v tailscale >/dev/null && echo " (Tailscale included)")"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update >>"$log" 2>&1
  apt-get -y upgrade >>"$log" 2>&1
  echo "==> Updating BrowserOS neo"
  cd /opt/neo || exit 1
  local before after
  before="$(docker compose images -q neo 2>/dev/null || true)"
  docker compose pull -q >>"$log" 2>&1
  docker compose up -d --wait --wait-timeout 300 >>"$log" 2>&1
  after="$(docker compose images -q neo 2>/dev/null || true)"
  docker image prune -f >/dev/null
  if [[ "$before" == "$after" ]]; then
    echo "==> Neo is already up to date."
  else
    echo "==> Neo updated and restarted. Logins and settings in /opt/neo/data are kept."
  fi
}
if ! command -v pveversion >/dev/null && [[ -f /opt/neo/compose.yaml ]]; then
  update_neo
  exit 0
fi

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
[[ "$NEO_SANDBOX" == true || "$NEO_SANDBOX" == false ]] || {
  echo "NEO_SANDBOX must be true or false." >&2
  exit 1
}
CTID="${CTID:-$(pvesh get /cluster/nextid)}"
if pct status "$CTID" >/dev/null 2>&1; then
  echo "CTID $CTID already exists. Set CTID=<free id>." >&2
  exit 1
fi

# ----- tailnet access: decide up front, before the slow part -----
# key = unattended with TS_AUTHKEY, login = print Tailscale's login URL, none = LAN only.
if [[ -n "$TS_AUTHKEY" ]]; then
  TS_MODE=key
else
  case "${TAILSCALE,,}" in
    y | yes | 1 | true) TS_MODE=login ;;
    n | no | 0 | false) TS_MODE=none ;;
    "")
      TS_MODE=none
      # Ask only when someone is at a terminal; unattended runs default to LAN only.
      if { : </dev/tty; } 2>/dev/null; then
        read -r -p "Join this container to your Tailscale tailnet for HTTPS access from your devices? [y/N] " ts_answer </dev/tty || ts_answer=""
        [[ "${ts_answer,,}" == y || "${ts_answer,,}" == yes ]] && TS_MODE=login
      fi
      ;;
    *)
      echo "TAILSCALE must be yes or no." >&2
      exit 1
      ;;
  esac
fi
trap 'echo "Failed. Container $CTID may exist; inspect with: pct enter '"$CTID"'  /  remove with: pct stop '"$CTID"'; pct destroy '"$CTID"'" >&2' ERR

# ----- ensure template, create + start -----
echo "==> Ensuring OS template"
pveam update >/dev/null
# Match the host's architecture: the index lists amd64 and arm64 builds side by
# side, and a plain version sort picks arm64 (its name sorts last).
HOST_ARCH="$(dpkg --print-architecture)"
TEMPLATE="$(pveam available --section system | awk -v t="$OS_TEMPLATE" -v a="_${HOST_ARCH}.tar" 'index($2, t) == 1 && index($2, a) {print $2}' | sort -V | tail -n1)"
[[ -n "$TEMPLATE" ]] || {
  echo "No template matching $OS_TEMPLATE" >&2
  exit 1
}
if ! pveam list "$TEMPLATE_STORAGE" 2>/dev/null | grep -q "$TEMPLATE"; then
  echo "    - Downloading $TEMPLATE"
  pveam download "$TEMPLATE_STORAGE" "$TEMPLATE" >/dev/null
fi

echo "==> Creating LXC $CTID ($CT_HOSTNAME)"
# nesting + keyctl: required for Docker inside an unprivileged LXC.
pct create "$CTID" "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}" \
  --hostname "$CT_HOSTNAME" \
  --cores "$CORES" --memory "$RAM_MB" --swap 1024 \
  --rootfs "${STORAGE}:${DISK_GB}" \
  --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp" \
  --unprivileged 1 \
  --features nesting=1,keyctl=1 \
  --onboot 1 >/dev/null

if [[ "$TS_MODE" != none && ! -c /dev/net/tun ]]; then
  # The bind mount below makes the container fail to start if the host has no TUN device.
  modprobe tun 2>/dev/null || true
  if [[ ! -c /dev/net/tun ]]; then
    echo "WARNING: this host has no /dev/net/tun (tun kernel module missing), so Tailscale is skipped." >&2
    TS_MODE=none
  fi
fi
if [[ "$TS_MODE" != none ]]; then
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
  NEO_VERSION="$NEO_VERSION" NEO_MODE="$NEO_MODE" NEO_SCREEN="$NEO_SCREEN" NEO_SANDBOX="$NEO_SANDBOX" \
  VIEWER_PORT="$VIEWER_PORT" MCP_PORT="$MCP_PORT" SCRIPT_URL="$SCRIPT_URL" \
  bash -s <<'INSTALL'
set -euo pipefail
# Quiet like community-scripts: one line per step on screen, everything else in the log.
LOG=/var/log/neo-install.log
exec 3>&1 >>"$LOG" 2>&1
step() { echo "    - $*" >&3; }
trap 'echo "    ! Failed. Last lines of $LOG:" >&3; tail -n 25 "$LOG" >&3' ERR
export DEBIAN_FRONTEND=noninteractive
step "Updating the OS"
apt-get update && apt-get -y upgrade
step "Installing base packages and Caddy"
apt-get install -y curl ca-certificates gnupg openssl jq caddy

# --- runtime: Docker CE + compose plugin ---
step "Installing Docker"
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
NEO_SANDBOX=${NEO_SANDBOX}
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
      NEO_SANDBOX: ${NEO_SANDBOX:-false}
    restart: unless-stopped
COMPOSE
if [[ "$NEO_SANDBOX" == true ]]; then
  # Chromium's sandbox needs user namespaces, which Docker's default seccomp and
  # AppArmor profiles deny (upstream README). Relax them for this container only.
  cat >/opt/neo/compose.override.yaml <<'OVERRIDE'
services:
  neo:
    security_opt:
      - seccomp=unconfined
      - apparmor=unconfined
OVERRIDE
fi
cd /opt/neo || exit 1
step "Pulling the BrowserOS neo image (~1 GB)"
docker compose pull -q
step "Starting Neo and waiting until it's ready (up to 5 minutes)"
docker compose up -d --wait --wait-timeout 300

# --- auth + Host-rewriting reverse proxy ---
step "Configuring Caddy (passwords, token, Host rewrite)"
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

# --- `update` command, as in community-scripts: re-runs this installer, which
# detects it's inside the container and switches to update mode ---
echo "bash -c \"\$(curl -fsSL ${SCRIPT_URL})\"" >/usr/bin/update
chmod +x /usr/bin/update

# --- console access, as in community-scripts ---
step "Enabling console autologin and setting a root password"
# The Proxmox UI's Console tab logs straight in as root, as in community-scripts.
# Anyone granted VM.Console on this CT therefore gets root in it.
mkdir -p /etc/systemd/system/container-getty@1.service.d
cat >/etc/systemd/system/container-getty@1.service.d/override.conf <<'GETTY'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear --keep-baud tty%I 115200,38400,9600 $TERM
GETTY
systemctl daemon-reload
systemctl restart container-getty@1.service
# A root password for other logins (other ttys, su). SSH keeps Debian's default of
# refusing root password logins.
ROOT_PASS="$(openssl rand -base64 18 | tr -dc 'a-zA-Z0-9')"
echo "root:${ROOT_PASS}" | chpasswd

IP="$(hostname -I | awk '{print $1}')"
cat >/root/neo.creds <<CREDS
Viewer:        http://${IP}:${VIEWER_PORT}   (user: neo  password: ${VIEWER_PASS})
MCP:           http://${IP}:${MCP_PORT}/mcp
MCP token:     ${MCP_TOKEN}
Root password: ${ROOT_PASS}   (the Proxmox console logs in automatically)
CREDS
chmod 600 /root/neo.creds

step "Cleaning up"
apt-get -y autoremove && apt-get -y autoclean
INSTALL

# ----- optional: tailnet access over HTTPS -----
# Neo already works on the LAN at this point, so a Tailscale failure only warns.
setup_tailscale() {
  echo "==> Installing Tailscale"
  pct exec "$CTID" -- bash -c 'curl -fsSL https://tailscale.com/install.sh | sh >>/var/log/neo-install.log 2>&1' || return 1
  if [[ "$TS_MODE" == key ]]; then
    # Hand the key over as a mode-600 file, never on a command line where `ps` would show it.
    local keyfile
    keyfile="$(mktemp)"
    chmod 600 "$keyfile"
    printf '%s' "$TS_AUTHKEY" >"$keyfile"
    pct push "$CTID" "$keyfile" /root/.ts-authkey --perms 600
    rm -f "$keyfile"
    # shellcheck disable=SC2016  # expanded inside the container, not here
    pct exec "$CTID" -- bash -c 'rc=0; tailscale up --auth-key=file:/root/.ts-authkey --hostname="$1" || rc=$?; rm -f /root/.ts-authkey; exit "$rc"' _ "$CT_HOSTNAME" || return 1
  else
    echo
    echo "==> Log in to Tailscale: open the URL below and approve this device."
    echo "    The installer continues once you've approved it (gives up after 10 minutes)."
    pct exec "$CTID" -- tailscale up --hostname="$CT_HOSTNAME" --timeout=10m || return 1
  fi
  pct exec "$CTID" -- tailscale serve --bg --https=443 "http://127.0.0.1:${MCP_PORT}" >/dev/null
  pct exec "$CTID" -- tailscale serve --bg --https=8443 "http://127.0.0.1:${VIEWER_PORT}" >/dev/null
  local ts_name
  ts_name="$(pct exec "$CTID" -- bash -c "tailscale status --json | jq -r '.Self.DNSName'" | sed 's/\.$//')"
  [[ -n "$ts_name" && "$ts_name" != null ]] || return 1
  pct exec "$CTID" -- bash -c 'cat >>/root/neo.creds' <<CREDS

Tailnet MCP:    https://${ts_name}/mcp
Tailnet viewer: https://${ts_name}:8443
CREDS
  AGENT_MCP_URL="https://${ts_name}/mcp"
}
# Default to the LAN address; setup_tailscale switches it to the tailnet one on success.
AGENT_MCP_URL="http://$(pct exec "$CTID" -- hostname -I | awk '{print $1}'):${MCP_PORT}/mcp"
if [[ "$TS_MODE" != none ]] && ! setup_tailscale; then
  echo "WARNING: Tailscale setup failed. Neo is still reachable on your LAN." >&2
  echo "         Retry inside the container: pct exec $CTID -- tailscale up --hostname=$CT_HOSTNAME" >&2
fi

# ----- report -----
trap - ERR
# The ready-to-paste agent command, with the tailnet URL if Tailscale is up, else the LAN one.
# shellcheck disable=SC2016  # expanded inside the container, not here
pct exec "$CTID" -- bash -c 'token="$(awk "/^MCP token:/ {print \$3}" /root/neo.creds)"
printf "\nClaude Code:\n  claude mcp add --transport http neo %s --header \"Authorization: Bearer %s\"\n" "$1" "$token" >>/root/neo.creds' _ "$AGENT_MCP_URL"
RULE="================================================================================"
echo
echo "$RULE"
echo "  BrowserOS neo is ready  (container $CTID)"
echo "$RULE"
pct exec "$CTID" -- cat /root/neo.creds
echo "$RULE"
echo "  Save these now. Show them again with: pct exec $CTID -- cat /root/neo.creds"
echo "  Next: open the viewer and sign in to your sites once; logins persist."
echo "  Update: type 'update' in the container console, or: pct exec $CTID -- update"
echo "$RULE"
