# BrowserOS neo on Proxmox

`browseros-neo-lxc.sh` creates a Debian 13 LXC on a Proxmox VE host and runs
[BrowserOS neo](https://github.com/browseros-ai/BrowserOS) in it: the official
`ghcr.io/browseros-ai/neo` image in Docker, with Caddy in front.

| Port | What | Auth |
|---|---|---|
| `6080` | noVNC viewer: see and drive the browser, sign in to your sites | basic auth (`neo` + generated password) |
| `9010` | MCP server at `/mcp` (plus Neo's read-only `/v1` API) | `Authorization: Bearer <token>` |

Caddy also rewrites the Host header to loopback. Neo's MCP server only accepts
`Host: localhost / 127.0.0.1 / ::1` and has no setting to change that, so
without the rewrite any client that isn't on the box gets a 403.

## Install

Run this as root in the Proxmox VE shell:

```sh
bash -c "$(curl -fsSL https://raw.githubusercontent.com/xyzhub/browseros-neo-proxmox/main/browseros-neo-lxc.sh)"
```

It first asks whether to join the container to your Tailscale tailnet. If you
say yes, it prints Tailscale's login URL near the end; open it and approve the
device, and you also get HTTPS addresses on your tailnet. Answer no (the default)
for LAN-only access.

At the end it prints the URLs, the viewer password, the MCP token, a generated
root password, and a `claude mcp add` command you can paste as-is. They're also
saved in the container at `/root/neo.creds`.

The Console tab in the Proxmox UI logs in as root automatically, as with the
community-scripts helpers. Use the root password for other logins. SSH keeps
Debian's default of refusing root password logins.

Then open the viewer and sign in to the sites your agents should use. The
profile lives in `/opt/neo/data` inside the LXC and survives restarts and updates.

### Options (environment variables)

| Variable | Default | Notes |
|---|---|---|
| `CTID` | next free ID | |
| `CT_HOSTNAME` | `neo` | |
| `CORES` / `RAM_MB` / `DISK_GB` | `2` / `4096` / `16` | Chromium plus a virtual display. 2 GB of RAM works for light use |
| `STORAGE` / `TEMPLATE_STORAGE` / `BRIDGE` | `local-lvm` / `local` / `vmbr0` | |
| `NEO_VERSION` | `latest` | Image tag. Only `latest` is currently built for both amd64 and arm64 |
| `NEO_MODE` | `hosted` | `desktop` restores the full BrowserOS tool set (skills, human help) |
| `NEO_SCREEN` | `1600x1000` | The starting size; the viewer resizes it after that |
| `NEO_SANDBOX` | `false` | `true` turns on Chromium's sandbox by relaxing Docker's seccomp/AppArmor profiles for the neo container only. Not yet tested inside an LXC |
| `TAILSCALE` | ask | `yes` joins your tailnet through the login URL; `no` skips it. When unset, the script asks, or skips Tailscale if no terminal is attached |
| `TS_AUTHKEY` | empty | Joins your tailnet unattended with this auth key instead of the login URL. Use an ephemeral, single-use key |

With Tailscale, MCP is at `https://<name>.<tailnet>.ts.net/mcp` and the viewer is on
port `8443`. Tailscale's usual key-expiry rules apply, so disable key expiry for the
device in the admin console if it should stay connected.

Put options in front of the command, for example:

```sh
TAILSCALE=yes RAM_MB=6144 bash -c "$(curl -fsSL https://raw.githubusercontent.com/xyzhub/browseros-neo-proxmox/main/browseros-neo-lxc.sh)"
```

## Connect an agent

```sh
claude mcp add --transport http neo http://<lxc-ip>:9010/mcp \
  --header "Authorization: Bearer <token>"
```

Over the tailnet, use `https://<name>.<tailnet>.ts.net/mcp` with the same header.

## Update

Type `update` in the container's console (`pct enter <CTID>`, or the Console tab
in the Proxmox UI). From the host, `pct exec <CTID> -- update` does the same.

Like the community-scripts helpers, `update` re-runs this installer inside the
container. The installer sees an existing install there and switches to update
mode: it upgrades the OS packages (Tailscale included) and pulls and restarts the
latest Neo image. Logins and settings in `/opt/neo/data` are kept.

## Security notes

- Whoever has the token or the viewer password controls a browser that's signed in to your accounts.
- On the LAN the ports are plain HTTP, so the token travels unencrypted. Use the Tailscale
  option for HTTPS, or keep the LXC on a trusted network.
- By default Chromium runs without its sandbox, which is the upstream image's default under
  Docker, because Docker's default seccomp profile blocks the user namespaces it needs. A
  malicious page that exploits a renderer bug then has the whole container's privileges
  (which still sit inside an unprivileged LXC). `NEO_SANDBOX=true` turns it on.
- `TS_AUTHKEY` goes into the container as a mode-600 file, so it never appears on a command
  line, and the file is deleted after `tailscale up`. Use an ephemeral, single-use key.

## Troubleshooting

- **Docker fails to start containers** (for example `permission denied` from runc on
  sysctl/procfs). This is a known Docker-in-unprivileged-LXC issue with some runc/AppArmor
  combinations. Check `pct exec <CTID> -- journalctl -u docker` and the Proxmox forum for
  your PVE version.
- **Neo logs:** `pct exec <CTID> -- docker compose -f /opt/neo/compose.yaml logs`
- **Caddy logs:** `pct exec <CTID> -- journalctl -u caddy`
- **Remove everything:** `pct stop <CTID> && pct destroy <CTID>`. Nothing is installed on the host.
