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

At the end it prints the URLs, the viewer password and the MCP token. They're
also saved in the container at `/root/neo.creds`.

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
| `TS_AUTHKEY` | empty | A Tailscale auth key. Joins the LXC to your tailnet and serves MCP at `https://<name>.<tailnet>.ts.net/mcp` and the viewer on port `8443` |

Put them in front of the command, for example:

```sh
TS_AUTHKEY=tskey-auth-… RAM_MB=6144 bash -c "$(curl -fsSL https://raw.githubusercontent.com/xyzhub/browseros-neo-proxmox/main/browseros-neo-lxc.sh)"
```

## Connect an agent

```sh
claude mcp add --transport http neo http://<lxc-ip>:9010/mcp \
  --header "Authorization: Bearer <token>"
```

Over the tailnet, use `https://<name>.<tailnet>.ts.net/mcp` with the same header.

## Update

```sh
pct exec <CTID> -- neo-update
```

## Security notes

- Whoever has the token or the viewer password controls a browser that's signed in to your accounts.
- On the LAN the ports are plain HTTP, so the token travels unencrypted. Use the Tailscale
  option for HTTPS, or keep the LXC on a trusted network.
- Inside the container, Chromium runs without its sandbox. That's the upstream image's
  default under Docker; see the upstream README to enable it.

## Troubleshooting

- **Docker fails to start containers** (for example `permission denied` from runc on
  sysctl/procfs). This is a known Docker-in-unprivileged-LXC issue with some runc/AppArmor
  combinations. Check `pct exec <CTID> -- journalctl -u docker` and the Proxmox forum for
  your PVE version.
- **Neo logs:** `pct exec <CTID> -- docker compose -f /opt/neo/compose.yaml logs`
- **Caddy logs:** `pct exec <CTID> -- journalctl -u caddy`
- **Remove everything:** `pct stop <CTID> && pct destroy <CTID>`. Nothing is installed on the host.
