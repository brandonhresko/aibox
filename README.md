<p align="center">
  <h1 align="center">aibox</h1>
  <p align="center"><strong>Persistent Docker sandboxes for Claude Code</strong></p>
  <p align="center">
    <a href="https://www.npmjs.com/package/aibox-cli"><img src="https://img.shields.io/npm/v/aibox-cli" alt="npm" /></a>
    <a href="https://www.npmjs.com/package/aibox-cli"><img src="https://img.shields.io/npm/dm/aibox-cli" alt="downloads" /></a>
    <a href="https://github.com/blitzdotdev/aibox/blob/main/LICENSE"><img src="https://img.shields.io/github/license/blitzdotdev/aibox" alt="license" /></a>
  </p>
</p>

> *One command into a yolo-mode Claude Code sandbox. Nothing gets destroyed behind your back.*

```bash
cd myproject && aibox
```

aibox runs Claude Code with `--dangerously-skip-permissions` inside a Docker container, so the agent can run wild while your Mac stays clean. One container per project, all sharing a single persistent home volume — one login, one session history, everything survives.

## Quickstart

```bash
npm install -g aibox-cli    # 1. install
cd myproject                # 2. go to your project
aibox                       # 3. run (builds the image on first use)
```

## How it works

- **One container per project directory.** `aibox` in a project creates (or re-attaches to) that project's container. Open more terminal tabs and run `aibox` again — they attach to the same container.
- **Your project is bind-mounted at its real path.** Changes sync both ways, paths inside the container match your Mac.
- **One shared home volume (`aibox-home`).** Claude login, every session, shell history, and the `claude` binary itself live in a Docker volume mounted at `/home/aibox` in every container. Log in once, resume any session from any project, forever.
- **Nothing is destroyed implicitly.** Exiting Claude leaves the container running in the background (idle containers cost ~nothing) — the next `aibox` attaches instantly. `aibox stop` stops it; a stopped container keeps everything, including packages you apt-installed. Containers are only recreated when the image changes, and the home volume survives even that.
- **Always yolo.** The container *is* the sandbox. No permission prompts, full sudo inside.

## Dev servers

Anything listening on any port inside the container is instantly reachable from your browser:

```
http://<port>.<project>.aibox.localhost
```

Claude starts `vite` on 5173 in project `myapp` → open `http://5173.myapp.aibox.localhost`. No ports to publish, no restarts, no config — a tiny shared Caddy proxy on the Docker network reaches any container port directly, WebSockets/HMR included.

Works out of the box in Chrome, Edge, and Firefox (`*.localhost` resolves to loopback natively). Safari needs macOS 26+. CLI tools like `curl` need `--resolve` (the system resolver doesn't do `*.localhost`).

## Backup & restore

Everything worth keeping is in one volume, so backup is one file:

```bash
aibox backup                 # ~/aibox-backups/aibox-home-<ver>-<timestamp>.tar.gz
aibox backup /some/dir       # custom destination
aibox restore <backup.tar.gz> # replaces the volume (auto safety-backup first)
```

Backups are safe to take while sessions are running.

## Migrating from aibox v1

v2 is a clean break: one always-yolo container per project, one shared home volume, and no destructive lifecycle. A standalone script merges all your v1 data — every per-image `aibox-auth-*` volume **and** any old backup folders — into the new volume:

```bash
# npm installs ship the script next to the CLI:
bash "$(npm root -g)/aibox-cli/scripts/migrate-to-v2.sh" [old-backup-dir ...]

# or fetch it directly:
curl -fsSL https://raw.githubusercontent.com/blitzdotdev/aibox/main/scripts/migrate-to-v2.sh | bash -s -- [old-backup-dir ...]
```

Sessions merge file-by-file (nothing is ever overwritten or deleted; sources are read-only), `.claude.json` is merged newest-wins, and the script prints — but never runs — the cleanup commands for old v1 resources.

## Commands

| Command | What it does |
|---------|-------------|
| `aibox` / `aibox claude [args]` | Start/attach the project container, run Claude Code (yolo). Args pass through verbatim (`--resume`, `-p`, ...). `aibox --resume` works too |
| `aibox shell [cmd]` | zsh in the container, or run a one-off command |
| `aibox stop [--all]` | Stop this project's container (`--all`: everything incl. proxy). Loses nothing |
| `aibox status` | Containers, dev URLs, home volume size |
| `aibox backup [dir]` | Snapshot the home volume to a tar.gz |
| `aibox restore <file>` | Restore a backup (safety-backup of current state first) |
| `aibox update` | Update the CLI; image rebuilds automatically on next run |
| `aibox version` / `help` | Versions + docker state / this table's long form |

## Config

`~/.aibox/config` (key=value, all optional):

```
node_version=24        # base image: node:<this>-bookworm
proxy_port=80          # host port for the dev-server proxy
backup_dir=~/aibox-backups
```

The image is `node:<version>-bookworm` (Debian) plus a few basics (zsh, sudo, ripgrep, fzf, jq, less, procps) — Claude apt-installs anything else on demand, and it persists across stop/start. To make custom tooling survive image rebuilds too, put extra Dockerfile lines in `~/.aibox/Dockerfile.extra`.

## Prerequisites

Built for macOS; works on Linux too (any running Docker daemon). On macOS, Docker via [Colima](https://github.com/abiosoft/colima), [OrbStack](https://orbstack.dev), or [Docker Desktop](https://www.docker.com/products/docker-desktop/):

```bash
brew install colima docker && colima start
```

aibox auto-starts an installed-but-stopped runtime; it won't install one for you.

Note on the dev-server proxy port: the proxy asks Docker for `127.0.0.1:80` only, but some Colima versions ignore the loopback restriction and publish the port on your LAN. Everything behind it is your own yolo-mode dev traffic, but if that matters to you, keep Colima current (or use OrbStack/Docker Desktop).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Design/requirements for v2 are in [REVAMP.md](REVAMP.md).

## License

MIT
