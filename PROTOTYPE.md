# AI Box Minimal Sandbox Prototype

## 0. Status

This document is the specification and the development plan for the next AI
Box prototype. It is a planning document, not a description of the current
implementation. Implementers work from this document. Where it is ambiguous,
take the conservative reading (refuse rather than act, preserve rather than
replace) and note the choice in the commit message.

Second revision, 2026-09-04, after three rounds of review. For this branch it
supersedes two settled decisions in `REVAMP.md`: D5 (one global home volume
sliced per project) and D9 (wildcard Caddy proxy). `REVAMP.md` stays in the
repository as the history of v2. Statements marked "verified" were tested on
Docker Desktop 29 (cgroup v2) on macOS 26 during review.

The prototype starts from the Claude revamp branch and deliberately narrows the
product. Its purpose is to validate one layer well: a persistent, isolated local
execution environment for AI coding tools and ordinary development commands.

The adversarial test for every decision below: does AI Box make entering a
persistent development environment predictably safer and easier than
remembering Docker commands? Its value comes from reliable lifecycle behavior
and useful errors, not from features.

## 1. Product boundary

AI Box owns the local sandbox lifecycle. It creates, starts, enters, inspects,
stops, and explicitly removes project environments backed by Docker.

AI Box does not own the interface or transport used to reach the host. A user
may work locally or choose Codex Remote, Claude Remote Control, SSH, Tailscale,
VS Code Remote SSH, a browser terminal, or another tool. Those products reach
the computer; AI Box provides the project environment on that computer.

```text
user-chosen interface
        |
user-chosen transport
        |
AI Box project sandbox
        |
Docker runtime
```

> AI Box preserves the environment. The agent preserves the conversation. The
> user's transport preserves access.

## 2. Prototype goals

1. Start or recover one persistent sandbox for the current project.
2. Run any command inside that sandbox without agent-specific orchestration.
3. Keep the selected project writable while mounting nothing else from the
   host.
4. Preserve the sandbox home across disconnects, stops, and container
   replacement.
5. Keep destructive and replacing lifecycle operations explicit.
6. Support practical CPU, memory, and process limits using Docker-native
   controls, changed live where Docker allows it.
7. Reach a dev server inside the sandbox from the host browser through an
   explicit, loopback-only forward that never restarts the sandbox.
8. Remain understandable enough that a user can inspect the generated Docker
   resources and know where work is running.
9. Allow callers to select a project directory and a compatible container image
   without changing directories or editing the project.
10. Forward host environment values only when the user names them explicitly.

## 3. Explicit non-goals

The first prototype will not include:

- A web, desktop, or mobile UI.
- A hosted relay, account system, or remote-control protocol.
- SSH, VPN, Tailscale, or tunnel provisioning.
- Claude or Codex session-history parsing.
- Push notifications, approvals, task boards, or agent orchestration.
- Automatic worktree or pull-request management.
- Wildcard dev-server hostnames or a shared reverse proxy.
- Automatic installation of Docker, Homebrew, coding agents, or host services.
- Backup, restore, or CLI self-update commands. A manual export and import
  procedure is documented instead (section 5.3).
- Compatibility with arbitrary container images. The default image,
  derivatives, and independently built images that satisfy the fixed contract
  are supported; AI Box does not adapt incompatible images (section 5.9).
- Shared authentication across projects (section 6).
- A claim that ordinary Docker containers are equivalent to microVM isolation.
- Cloud infrastructure provisioning.

The revamp's `serve`, `sessions`, and `rc-resume` functionality is therefore
outside the prototype core. It may later exist as a separate adapter, but it
must not determine the core architecture.

## 4. Implementation strategy

### 4.1 Carve, do not rewrite

The prototype is a carve-down of the existing `bin/aibox`. The revamp's
container core went through several review rounds and encodes Docker behavior
that must not be rediscovered. Retain as-is:

- Docker readiness checks and auto-start of an installed but stopped runtime.
- Image availability check and the embedded Dockerfile build.
- Container startup polling.
- TTY allocation only when stdin and stdout are terminals.
- `--restart unless-stopped` and `--init` around `sleep infinity`.
- Same-path bind mounting of the project.
- Bash 3.2 compatibility: no associative arrays, no `mapfile`, no `${var,,}`.
- The existing `run`, `shell`, `stop`, and `status` mechanics.

### 4.2 Inherited code that must be corrected

The inherited lifecycle protections are useful but not safe enough to keep
unchanged. Each of these is a defect in the current `_ensure_container` and
its helpers, and each has a specified fix in section 5.6:

- The creation lock is stolen after roughly 15 seconds without establishing
  that its owner died.
- A failed `docker top` collapses to an apparent count of zero active
  processes, which reads as "safe to replace".
- Idle processes are excluded by matching the text `sleep infinity` rather than
  by identifying the actual idle processes.
- The creation lock is released before the requested command launches, leaving
  a window in which another invocation can replace the container.
- Readiness waits on the Claude installer's marker; readiness must be
  independent of any agent installer.

### 4.3 Deletions

Removed in the first carve. All of it remains in Git history and may return
later as adapters or separately scoped features:

- `serve`, `sessions`, `rc-resume`, and the embedded UI payloads.
- Caddy generation, the shared proxy, and its lifecycle.
- The Claude installer in the entrypoint, the Claude-specific `settings.json`
  and `CLAUDE.md` edits, and the `claude`-default dispatch that turned
  `aibox --resume` into a Claude call.
- `--yolo` and `--copy`.
- The volume-subpath slice mounts, the global layout migration, the helper
  containers that supported them, and `scripts/migrate-to-v2.sh`.
- `backup`, `restore`, `update`, and the npm update check.
- `ANTHROPIC_*` environment forwarding.
- Automatic container replacement from `run` and `shell`.

## 5. Architecture

### 5.1 Identity and labels

- One persistent sandbox per absolute project directory.
- Project identity is the canonical absolute path, symlinks resolved. Moving or
  renaming a project directory changes its identity; the old sandbox remains
  until removed.
- The sandbox name is `aibox-<slug>-<hash>`: `<slug>` is the sanitized
  directory basename and `<hash>` is a prefix of the SHA-256 of the path. The
  project container, its private home volume, and its network all share that
  name. Docker namespaces containers, volumes, and networks separately.
- Every resource AI Box creates carries these labels: `aibox.schema=3`,
  `aibox.path`, `aibox.slug`, `aibox.hash`, `aibox.version` (creating CLI
  version), and `aibox.role` (`sandbox` or `forward`). Containers also carry
  `aibox.image-source` (`default` or `custom`). Forwarders also carry
  `aibox.forward.host` and `aibox.forward.port`.
- Schema 3 distinguishes prototype resources from v1 (unlabeled, compose) and
  v2 (`aibox.layout=2`) resources. See section 5.17.
- Multiple terminals may execute commands in the same sandbox. They share one
  writable checkout and one home; AI Box does not isolate terminals from each
  other.
- Named instances and automatic task-level containers are deferred.

### 5.2 Workspace exposure

- Mount only the selected project directory from the host.
- Mount it read/write at the same absolute path inside the container.
- Do not mount the host home directory or unrelated parent directories.
- Do not mount the Docker socket.
- Do not automatically mount host SSH keys, cloud credentials, Git
  configuration, or other dotfiles.
- A copied or ephemeral workspace mode is a later, separate capability.

The default sandbox protects the rest of the host filesystem; it does not
protect the selected project from intentional or accidental edits. Git remains
the primary recovery mechanism for project files.

### 5.3 Persistent state

- Each project gets one ordinary named Docker volume as its private home,
  mounted at `/home/aibox`.
- Agent credentials, shell configuration, caches, agent state, and
  user-installed tooling inside that home are opaque to AI Box.
- The home volume survives container replacement and is deleted only by
  `remove --purge`.
- Volume semantics, verified: an empty named volume receives the image's
  contents at the mount path on first use. A populated volume does not receive
  later image contents. Consequence: anything the image places in the home
  directory reaches new sandboxes only, never existing ones, so agent binaries
  and other image-managed tools must be installed outside the home directory.
  Only authentication and state belong in the home volume. An in-home Claude
  install measured roughly 650 MB and would be duplicated per project.
- The core uses no `volume-subpath` mounts, helper containers, layout markers,
  or layout migration. The mount code is a single list so that a future
  adapter can append entries; no other adapter machinery exists in the core.
- The entrypoint ensures the home mountpoint is owned by the container user.
  It does not run a recursive ownership pass; data copied in by hand is chowned
  at copy time.
- Do not rely on the container writable layer for state that must survive an
  image update. `apt` installs persist across stop and start but reset on
  replacement; a derivative image (section 5.9) is the way to keep them.

Manual export and import, documented in the README in place of backup commands.
The sandbox must be stopped for a consistent copy:

```sh
docker run --rm -v <name>:/v:ro -v "$PWD":/out alpine tar czf /out/<name>.tgz -C /v .
docker run --rm -v <name>:/v    -v "$PWD":/in  alpine sh -c 'cd /v && tar xzf /in/<name>.tgz'
```

### 5.4 Sandbox definition and change policy

The running container is the sandbox definition. `docker inspect` is the read
API: resource limits from `HostConfig`, the image by ID, mounts from the mount
list, image source from the label. AI Box writes no per-sandbox definition file
on the host. Two consequences are stated plainly to users:

- `remove` retains home data, not environment configuration. Image choice and
  limits are gone with the container; `up` recreates from defaults.
- Replacement (section 5.5) reads the old container's settings before acting
  and carries them forward. Omitted `up` flags preserve existing values.

Replacement is explicit. `run` and `shell` start or enter the existing
environment and never replace it. Having no active processes does not make an
environment disposable: system packages and other writable-layer changes are
part of it. When the default image has changed, `run` and `shell` print a
one-line notice naming `aibox up`. The only exception is a container in the
`Created` state that never ran; it has no environment to lose and is replaced.

Verified live-versus-replace behavior of `docker update`:

| Setting | Changes live? | Notes |
|---|---|---|
| CPU quota (`--cpus`) | Yes, raise or lower | Cannot be cleared once set. Clearing is a replacement |
| Memory | Yes, only with `--memory-swap` passed alongside | Alone the update is rejected. Swap is set equal to memory so the limit is real. Cannot be cleared live; clearing is a replacement. Lowering below current use triggers reclaim or OOM: warn first |
| Process limit | Yes, including clearing | |
| Restart policy | Yes | |
| Image | No | Compared by image ID, never by tag |
| Mounts | No | |
| Network membership | Live via `docker network connect`, unused | |
| Ports on the project container | Never used | Forwards are sidecars |
| Hostname, extra hosts, init, user, working directory, devices, labels | No | |

`docker update` also applies to stopped containers and takes effect at the next
start.

Lifecycle transitions:

| Container state | Command | Result |
|---|---|---|
| absent | `up`, `run`, `shell`, `port-forward` | create, start, wait for ready |
| `Created`, never ran | `up`, `run`, `shell` | replace (nothing to lose) |
| stopped | `run`, `shell` | start, enter; notice if image is stale |
| stopped | `port-forward` | start without replacement, then create or reuse the sidecar |
| stopped | `up` | start; apply live changes; replace if a replace-class change is requested or the image is stale |
| running, idle | `run`, `shell` | enter; notice if image is stale |
| running, idle | `up` | apply live changes; replace if needed |
| running, active | `run`, `shell` | enter |
| running, any activity | `port-forward` | create or reuse the sidecar without replacement |
| running, active | `up`, live-class only | apply |
| running, active | `up`, replace-class | refuse, print the command to run after `stop` |
| foreign schema (section 5.17) | any | refuse |
| any | `stop` | stop container and its forwarders |
| any | `remove` | stop; remove container, forwarders, network; keep volume; say so |
| any | `remove --purge` | as `remove`, then delete the volume after confirmation |

Clearing a limit is explicit: `--cpus 0`, `--memory 0`, or `--pids 0` means
unlimited. Clearing the process limit is live; clearing CPU or memory is a
replacement.

Critical lifecycle invariant:

> AI Box may automatically start a stopped container. It must never destroy a
> running container that has processes in it, and it must never replace a
> container except from an explicit `up`.

### 5.5 Replacement procedure

`up` replaces a container in this order. The mutex (section 5.6) is held from
step 1 through step 9.

1. Acquire the sandbox mutex.
2. Establish idleness: no live session markers, `docker top` succeeds, and it
   shows only the idle processes. Any failure to establish this refuses the
   replacement.
3. Read the old container's image source, image ID, limits, and restart
   policy. Merge the requested changes over them.
4. Resolve the target image: build the default image if its fingerprint is
   stale or it is missing; validate a custom image against the contract
   (section 5.9). Fail here before anything is touched.
5. Record whether the old container was running, then stop it. Both containers
   mount the same home volume, and two entrypoints must never write to it
   concurrently.
6. Rename the old container aside, to `<name>.prev`.
7. Create the replacement under the canonical name with the merged settings,
   start it, and wait for the readiness marker.
8. On success, remove the old container and restart any stopped forwarders.
9. On failure, remove the failed replacement if it exists, rename the old
   container back, and restore its previous state: start it only if it was
   running. Report what happened.

Recovery restores the previous container, not necessarily every filesystem
change: a failed replacement's entrypoint may have written to the shared home.
The entrypoint is therefore restrained and idempotent: it creates files only
when absent and changes ownership only on the mountpoint.

### 5.6 Concurrency, locking, and safety checks

Sandbox mutex:

- One lock per sandbox at `~/.aibox/locks/<name>`, implemented as a symlink
  whose target is the owner's PID. Symlink creation is atomic and carries the
  owner, so there is no window between taking the lock and recording who holds
  it. Verified on macOS bash 3.2.
- A waiter polls. A lock whose owner PID is dead, or alive but not an `aibox`
  process, is stale: the waiter removes it and retries.
- A holder releases only a lock that still names its own PID.
- Residual case, accepted and documented: two waiters racing to remove the same
  dead lock.

Session markers:

- `run` and `shell` write `~/.aibox/sessions/<name>/<pid>` before acquiring the
  mutex and remove it on exit through a trap. A marker whose PID is dead is
  stale and ignored.
- `up` reads markers only while holding the mutex. Because a session's marker
  write precedes its mutex acquisition, any session `up` does not see will
  block on the mutex and then find the post-replacement state. This closes the
  window between a session's container check and its `docker exec`.

Idle-process identification:

- The container runs with `--init`, so the init process and its only child, the
  idle `sleep`, are the two expected processes. The implementation must not
  assume that `docker top` reports the init process as literal PID 1: Docker
  may report daemon-namespace PIDs. It reads the init PID from
  `docker inspect .State.Pid`, then reads `docker top` with PID, parent PID,
  and arguments and identifies that init plus its direct idle child. Anything
  else counts as active. Agents, dev servers, shells, and a `tmux` server all
  count. Milestones 2 and 4 verify the representation on Docker Desktop and
  native Linux respectively.
- `docker top` exit status is checked separately from its output. A failed
  inspection means "cannot establish safety" and refuses a replacement; it
  never reads as zero processes.

Readiness:

- The entrypoint removes and then writes a readiness marker after its own
  setup (mountpoint ownership, shell skeleton). `run`, `shell`, and `up` wait
  briefly for it. Readiness depends on nothing but the entrypoint.

### 5.7 Command surface and parsing

```text
aibox                                   # concise help plus this project's status; never launches an agent
aibox [--dir PATH] up [--image IMAGE] [--cpus N] [--memory SIZE] [--pids N] [--rebuild]
aibox [--dir PATH] run [--env NAME]... <command> [arguments...]
aibox [--dir PATH] shell [command...]
aibox [--dir PATH] stop [--all]
aibox [--dir PATH] status
aibox [--dir PATH] remove [--purge] [--yes]
aibox [--dir PATH] port-forward PORT|HOST_PORT:CONTAINER_PORT ...
aibox [--dir PATH] port-forward --list | --stop PORT | --stop-all
aibox version
aibox help
```

Parsing rules:

- Global flags are accepted only before the command word. `--dir` is the only
  global flag.
- `--image`, the resource flags, and `--rebuild` belong to `up` only. On `run`,
  a differing image could only replace silently, be ignored silently, or be
  deferred, and all three are wrong.
- `run` parses `--env` only between `run` and the program name. Everything from
  the program name on passes through verbatim. A `--` ends AI Box parsing.
- Unknown command: one-line error with a help hint, exit 2. No interactive
  prompts except the `remove --purge` confirmation, which `--yes` skips for
  scripts and tests.

Command semantics:

- `aibox run` is the fundamental agent-neutral operation: `aibox run codex`,
  `aibox run claude`, `aibox run npm test`. If the program is not found inside
  the sandbox, `run` prints an actionable message naming the two installation
  paths (install inside the persistent home, or bake into a derivative image)
  instead of a bare exit 127.
- `--dir` selects the project without requiring the caller to `cd` first,
  which is what scripts and user-chosen remote tools need. AI Box canonicalizes
  the path before deriving the identity and rejects broad targets: `/`, the
  user's home directory, `/Users`, `/home`, `/Volumes`, `/mnt`, `/tmp`, `/var`,
  `/etc`, `/usr`, `/opt`, `/private`, and any path containing `:`.
- `up` creates or starts the sandbox without running anything, applies limits,
  and is the only command that replaces a container. `--rebuild` rebuilds the
  default image with `--pull` and then replaces.
- `shell` opens `zsh`, falling back to `bash`, then `sh`. With arguments it
  runs them as a command.
- `stop` stops the container and this project's forwarders. `stop --all` stops
  every schema-3 container and forwarder on the daemon.
- `port-forward` follows the non-replacing lifecycle of `run` and `shell`: it
  creates the default sandbox if absent, starts it if stopped, and never
  replaces it. It refuses foreign resources. The sandbox mutex is held while
  the target is established and the sidecar is created, so an explicit `up`
  cannot replace the target between those operations.
- `remove` stops and removes the container, forwarders, and network, and states
  that the home volume is retained and how to delete it. `remove --purge` also
  deletes the volume after confirmation.
- Agent shortcuts may eventually alias `aibox run`, but the core must not
  depend on one agent's session format, remote-control service, or
  authentication layout.

### 5.8 Output and exit status

- Every AI Box notice, warning, and error goes to stderr. Under `run` and
  `shell`, stdout belongs to the program, so `aibox run cmd | other` works.
- `run` and `shell` exit with the program's exit status. AI Box's own failures
  exit 1; usage errors exit 2.
- `status`, `version`, `help`, and `port-forward --list` write their report to
  stdout.
- Forwarded environment values are never printed. Names may be.

### 5.9 Image

Default image:

- `node:<node_version>-bookworm` plus a small baseline: `zsh sudo ripgrep fzf
  jq less procps curl tmux`. Node stays because agent CLIs and MCP servers are
  overwhelmingly npm-distributed; `tmux` is the neutral detached-session tool
  (section 5.13).
- User `aibox`, UID 1000, home `/home/aibox`, passwordless sudo, login shell
  `zsh`. The base image's `node` user at UID 1000 is removed first.
- Tag `aibox:<cli-version>-node<node_version>`. Git checkouts run as version
  `dev`.
- Build fingerprint: the image carries a label with the SHA-256 of all AI Box
  controlled build inputs concatenated: the generated Dockerfile, the generated
  entrypoint, and `~/.aibox/Dockerfile.extra` if present. The image is rebuilt
  when the tag is missing or the label differs from the current fingerprint.
  This replaces the manual `docker rmi` step for development builds.
- "Build inputs unchanged" and "base image current" are separate questions.
  Only the first is checked automatically; `up --rebuild` answers the second
  by building with `--pull`.
- Built with `docker build --pull`.

Fixed compatibility contract for derivatives and custom images:

- User `aibox`, UID 1000, home `/home/aibox`.
- The entrypoint passes the command through (executes its arguments after its
  own setup).
- `sleep` and `sh` exist. `zsh` or `bash` is optional.
- AI Box supplies `--init`, the idle command, the working directory, and all
  mounts; the image sets none of them.
- Derivatives are built `FROM` the default image, either through
  `~/.aibox/Dockerfile.extra` (appended to the generated Dockerfile, so its
  contents are part of the fingerprint) or as a separately built image passed
  with `up --image`.
- A separately built custom image does not have to inherit from the default
  image, but it receives no compatibility adaptation: it is supported only if
  it independently satisfies every item in this contract. Derivatives are the
  recommended path.

Validation of `up --image IMAGE`, performed before an existing container is
touched:

- The image name is validated as a Docker reference before use.
- An inherited base label is a claim, not a check: a derivative can change its
  user, entrypoint, or files while keeping the label. So the image config is
  inspected for user and entrypoint, and the image is run once with a trivial
  command through its real entrypoint, checking the effective UID, the home
  directory, and the presence of `sleep`. This takes about a second and stays
  far smaller than arbitrary-image support.
- A custom image is recorded on the container as `aibox.image-source=custom`
  and is never replaced by the default when the CLI version changes.

Linux ownership: files the sandbox writes to the bind mount are owned by UID
1000 on a Linux host. Hosts whose user is not UID 1000 are a documented
limitation of the prototype, tested in milestone 2 rather than discovered
later.

### 5.10 Agent installation

- The core image supplies a small, documented Linux development baseline.
- AI Box does not silently install or update a particular coding agent.
- Users install tools inside the persistent project home, or bake them into a
  derivative image. Binaries baked into an image must live outside the home
  directory (section 5.3).
- Optional installation helpers or adapters must remain separable from the
  sandbox lifecycle.

### 5.11 Environment forwarding

- Do not copy the host environment wholesale into the sandbox.
- Persisted login state inside the private project home is the preferred agent
  authentication path.
- `run --env NAME` forwards the value of a named exported host variable. AI Box
  passes the bare name to Docker; the Docker CLI reads the value from its own
  environment and sends it in the API request, so the value never appears in a
  process argument list. Verified.
- A named variable that is not set in the host environment is an error, not an
  empty string.
- No provider-specific hard-coded lists such as only `ANTHROPIC_*` or
  `OPENAI_*`.
- Environment-file support is deferred until its path, storage, and accidental
  disclosure behavior are deliberately specified.

### 5.12 Networking and dev-server access

- Normal outbound networking is available for model APIs, package registries,
  Git hosting, and development dependencies.
- Each project gets its own user-defined bridge network, named after the
  sandbox, shared only with that project's forwarders. Containers on one
  user-defined bridge can reach each other's listening ports, so a shared
  bridge would let projects reach one another's dev servers and databases.
  The network is created by the first `up`, `run`, or `shell` and removed by
  `remove`.
- Capacity caveat: with Docker's default address pools each bridge takes a
  /16, which allows roughly thirty networks per daemon, and other tools consume
  them too. Address-pool exhaustion produces an actionable error naming the
  `default-address-pools` daemon setting, and the README documents it.
- `host.docker.internal` resolves to the host. Host network access is on.
- AI Box does not create a public listener, a remote ingress path, or an SSH
  server in any sandbox.
- Ports are never published on the project container itself: a published port
  is creation configuration, and adding one would require a replacement.
- AI Box refuses to operate against a remote Docker context. Bind paths belong
  to the daemon host, so the Docker endpoint must be a local socket.

Dev-server access is an explicit forward through a small sidecar:

```text
Browser
  |
127.0.0.1:HOST_PORT on the host
  |
socat sidecar container (the project's network)
  |
project container:CONTAINER_PORT
```

- `aibox port-forward 5173` publishes `127.0.0.1:5173` and relays to the
  project container's port 5173. `8080:3000` maps different host and container
  ports. Several specs may be given at once.
- The sidecar runs a pinned `alpine/socat` image relaying to the project
  container by name. socat resolves the name per connection, so a project
  container replaced under the same name is reachable again with no sidecar
  restart. Verified.
- Loopback only. The user's chosen transport, for example an SSH local forward,
  may make that endpoint reachable elsewhere.
- Raw TCP relay: WebSocket-based hot reload needs no special handling, and the
  browser sends a plain `localhost` Host header, which dev servers with host
  allowlists accept.
- The dev server must listen on the container's network interface, not only
  its own loopback (for example `vite --host`). `port-forward` prints this
  when it starts, and a connection-refused diagnosis repeats it.
- Sidecars carry the forward labels (section 5.1) and are found by label,
  never by name prefix.
- Lifecycle: `stop` stops the project's sidecars, `up` restarts stopped ones,
  `remove` removes them, and `status` and `port-forward --list` show them. A
  host port already in use is reported as such.
- This revives v1's `port-forward` from `main`, which published on all
  interfaces and located sidecars by name prefix. Both are corrected.

Remote-access compatibility. AI Box remains a headless CLI. Users reach the host
through SSH, Tailscale plus SSH, VS Code Remote SSH, Codex Remote SSH, Claude
Remote Control, a browser terminal, or another transport, then invoke the same
CLI they use locally. The core properties that make this work:

- Leading `--dir` with canonical absolute paths, and no assumption that the
  caller ran `cd`.
- Correct TTY and non-TTY behavior.
- A long-lived container independent of any terminal session, with
  `--restart unless-stopped`.
- Stable project identity, container naming, and user/home behavior.
- No automatic mounting of SSH keys or host credentials.
- Auto-start of an installed runtime is kept, including launching Docker
  Desktop or OrbStack on macOS, because it is what lets an always-on machine
  recover from a remote invocation. If the daemon does not come up within the
  wait, the error names the runtime and the command to start it. Installation
  is never attempted.

Codex Remote SSH or VS Code reaching the host does not automatically place their
processes inside AI Box. The prototype guarantees a stable CLI entrypoint.
Deeper one-click integrations can be adapters later.

### 5.13 Agent sessions

- The core exposes `aibox run <program> [arguments]`. The agent owns its
  transcript format, resume identifiers, retention, remote-control
  registration, and background semantics. AI Box owns the environment.
- `tmux` is in the baseline image as the neutral way to keep an interactive
  program alive across an SSH or terminal disconnect. A `docker exec` session
  ends with its terminal; the container does not.
- Warning to document prominently: removing the Claude-specific entrypoint
  removes the `cleanupPeriodDays` setting that stopped Claude Code from deleting
  transcripts idle for 30 days. Persistent storage prevents Docker from
  discarding files; it cannot prevent an agent from deleting its own data.
  Users set this in the agent's own settings, and a Claude adapter may later do
  it for them.

### 5.14 Resource controls

- Docker-native controls: CPU quota (`--cpus`), memory (`--memory`, with
  memory-swap set equal so the limit is real), and process count (`--pids`).
  Device or GPU access is off and deferred.
- Defaults: process limit 4096; CPU and memory unlimited unless configured.
  Global defaults live in `~/.aibox/config`; `up` flags override them for one
  sandbox; omitted flags preserve the sandbox's current values.
- Limits are applied live through `docker update` wherever section 5.4 allows.
  A live update that Docker rejects is reported verbatim and changes nothing.
- Disk usage is reported: the container's writable layer and the home volume
  size. Enforced disk quotas are deferred.
- AI Box does not write configuration into the project.

### 5.15 Host state and configuration

```text
~/.aibox/
  config             # key=value: node_version, cpus, memory, pids
  Dockerfile         # generated at build (regenerated each build)
  entrypoint.sh      # generated at build
  Dockerfile.extra   # optional, user-authored; part of the fingerprint
  locks/<name>       # sandbox mutexes (symlink -> owner PID)
  sessions/<name>/   # live session markers (one file per PID)
```

There are no per-sandbox definition files and no per-project files. The
sandbox definition is the container (section 5.4).

### 5.16 Diagnostics and status

- Verify that the Docker CLI exists and the daemon is reachable; auto-start an
  installed runtime; never install host dependencies.
- Actionable errors for: missing runtime, stopped daemon, remote Docker
  context, incompatible image, unsafe project path, failed mount, insufficient
  disk space (v1's host disk check before builds is retained), a program not
  found in the sandbox, a host port already in use, address-pool exhaustion,
  a foreign-schema resource, and a replacement refused because of active
  processes or a failed inspection.
- `aibox status` reports, for this project: path, sandbox name, image and
  whether it is stale, lifecycle state, configured limits, live CPU and memory
  use, writable-layer and home-volume disk use, active forwarders, and active
  sessions. A retained home volume with no container is reported as such with
  the command that recreates the container. Without a project context it lists
  every schema-3 sandbox on the daemon.
- Mount boundaries and forwarded environment variable names must be
  inspectable; secret values must not be displayed.
- A larger `doctor`, `disk`, `volumes`, `clean`, or `nuke` command family is not
  part of the first prototype.

### 5.17 Compatibility with existing resources

The prototype inherits v2's naming scheme and development image tag, so it must
prove ownership before touching anything:

- A container, volume, or network carrying the sandbox name but lacking
  `aibox.schema=3` is foreign. Every command refuses to adopt, start, modify,
  or remove it, and prints what it found and how to clear it by hand. In
  particular, a v2 container with slice mounts is never started by the
  prototype.
- `stop --all` and the no-project form of `status` operate only on schema-3
  resources.
- The v2 `aibox-home` volume and the v1 `aibox-auth-*` volumes are never read,
  written, or deleted by the CLI. `status` may note that legacy volumes exist.
- The build fingerprint (section 5.9) prevents reuse of a stale v2 image under
  the same development tag.
- Publishing metadata: the checkout has only the fork's `origin`, but
  `package.json` still links to the original repository and the disabled
  release workflow still targets the original npm package and Homebrew tap.
  Metadata and release ownership are resolved in milestone 4 before any
  distribution.

### 5.18 Security statement

The prototype's security promise is intentionally limited:

> Only the selected host directory is mounted. Commands can control that
> directory and their private container home; no other host path is mounted
> unless the user explicitly adds one.

- Processes may have administrative privileges inside the container; the
  default image has passwordless sudo.
- Docker socket access, privileged host mode, broad host mounts, and automatic
  credential forwarding remain off by default.
- Network access to the host and the internet is on. The promise is about
  mounted host paths, not host network reachability.
- On Linux hosts without user-namespace remapping, root inside the container is
  root on the bind-mounted project. Documentation must distinguish Docker's
  container boundary from stronger VM or microVM isolation.

### 5.19 Initial host support

- Validate first on macOS with the currently supported Docker-compatible
  runtime.
- Validate the same lifecycle on one current Linux Docker Engine host before
  describing the prototype as suitable for an always-on development station.
- Defer Windows and WSL support until path, ownership, and lifecycle behavior is
  intentionally designed and tested.

## 6. Shared authentication

Deferred. Shared login matters: re-authenticating Claude, Codex, and Git in
every project is friction, and the private-home decision is validated through
real use (section 7) before any of this is built. The core carries exactly one
constraint for it: the mount code stays a single list. Adapter machinery,
nested-mount ownership handling, and a migration design are out of scope until
an actual adapter needs them.

What a later spike must establish, Claude first, then Codex:

- Claude's config directory mixes shareable files (credentials, `.claude.json`,
  `settings.json`, plugins) with per-project state (`projects`,
  `history.jsonl`, `sessions`, `session-env`, `shell-snapshots`). A
  whole-directory mount shares too much.
- `.claude.json` is a single file that Claude Code rewrites whole; two sandboxes
  sharing it would overwrite each other's edits.
- A possible zero-mount path: `claude setup-token` issues a long-lived token
  read from `CLAUDE_CODE_OAUTH_TOKEN`, forwardable with `--env`. Test this
  first. No equivalent is known for Codex subscription auth.
- Codex keeps `auth.json`, `config.toml`, `sessions/`, and `history.jsonl`
  under `CODEX_HOME`. Confirm the layout.

## 7. Decisions to validate early

Three choices should be tested through real use before becoming permanent:

1. Whether a private home per project is acceptable or repeated agent login is
   too much friction.
2. Whether a writable bind mount is the correct default or users expect the
   original project directory to be protected automatically.
3. Whether an explicit `port-forward` is acceptable in place of the automatic
   wildcard URLs the revamp had.

Other useful observations: which resource limits users understand, whether
derivative images are sufficient for installing their preferred agents, and
whether `tmux` is enough for disconnect survival.

## 8. Selected ideas retained from the original main branch

The Claude revamp is already descended from the original `main`; this prototype
does not merge or cherry-pick that branch. It retains only the concepts that fit
the narrower execution-layer boundary:

- `--dir PATH` for explicit project selection.
- `--image IMAGE` (on `up`) and a user-controlled image customization path.
- Safe project-path and image-name validation.
- Docker readiness, disk-space, and lifecycle diagnostics.
- Inspectable Docker labels and useful status/resource reporting.
- `port-forward` with socat sidecars, corrected to loopback binding and
  label-based discovery.

Named instances, repository cloning, worktree orchestration, editor setup,
automatic host installation, Claude-specific permission modes, domain
allowlists, broad cleanup commands, shared `node_modules`, and session-driven
container shutdown remain intentionally excluded.

## 9. Development plan

This section is written for the agent implementing the prototype. Sections 1
through 8 are the contract; this section is how to deliver it.

### 9.1 Working rules

- Work in `bin/aibox`, a single bash file. Keep it bash 3.2 compatible (macOS
  ships 3.2). No associative arrays, no `mapfile`, no `${var,,}`.
- Runtime dependencies are the Docker CLI plus tools present on both macOS and
  Debian by default. No `jq`, `python`, or `node` on the host path.
- Carve, do not rewrite. Keep retained functions and their structure. Delete
  removed code entirely: no dead code, no feature flags, no compatibility
  shims for v1 or v2.
- The command surface is exactly section 5.7. Do not add commands or flags
  beyond it; if one seems necessary, stop and record the gap in the commit
  message or the pull request rather than adding it.
- AI Box writes on the host only under `~/.aibox/`, never into the project.
- All notices to stderr (section 5.8). Never print a forwarded value.
- Every guarantee gets a test in `scripts/smoke.sh` in the same milestone it is
  implemented, not afterwards. A milestone is not complete until the smoke
  script passes on Docker Desktop.
- `bin/aibox` and `scripts/smoke.sh` pass ShellCheck with no warnings.
  Directive comments that disable a check must say why.
- Never touch the developer's real resources. The v2 `aibox-home` volume, the
  v1 `aibox-auth-*` volumes, the existing v2 container, and any non-test
  sandbox are off limits to tests and to manual experiments. Tests create
  scratch project directories whose basename starts with `smk-`, and clean up
  every resource they created, found by their own labels.
- Tests must not run `stop --all` while non-test sandboxes exist on the
  daemon.
- Commit per milestone, or per coherent step within one, with a message that
  names the milestone. Do not squash milestones together.
- The README describes v2 until milestone 4. In milestone 1 add one banner
  line at its top saying so and pointing here. Do not rewrite it earlier.
- Do not reopen decisions in sections 1 through 8. If the document is
  ambiguous, take the conservative reading and note it in the commit.
- Size guide: the core should land near 600 lines. Passing 800 is a signal to
  stop and reconsider, not a hard limit.

### 9.2 Test strategy

`scripts/smoke.sh` is a bash script that exercises the real CLI against the
local Docker daemon:

- Creates one or more scratch projects under a temporary directory with the
  `smk-` basename prefix, runs the CLI against them with `--dir`, and asserts
  on observable state: `docker inspect` output, files in the volume, cgroup
  values read from inside the container, exit statuses, and stderr versus
  stdout content.
- Prints one `PASS` or `FAIL` line per check, continues past failures, and
  exits non-zero if any check failed.
- Cleans up everything it created through labels, including on interruption.
- Needs no interaction: purge tests use `--yes`.
- Simulates failures with a stub `docker` wrapper placed first on `PATH` where
  a real failure cannot be provoked, for example a failing `docker top`.
- Runs on macOS Docker Desktop for every milestone. Linux Docker Engine runs
  are required in milestones 2 and 4.

Synthetic fixtures first. A helper creates a home volume with fake dotfiles
and fake transcript files so persistence checks compare known content. The
real acceptance fixture, copied from the developer's v2 volume, is used only in
milestone 4 with the v2 container stopped, because a read-only mount protects
the source from the copy but does not make a consistent snapshot while
something is writing to it.

CI runs ShellCheck on every push. CI does not run the smoke script (it needs a
Docker daemon with the developer's characteristics); the milestone commit
message records the smoke run's result.

### 9.3 Milestones

| Milestone | Deliverable | Evidence required |
|---|---|---|
| 1. Settle the contract | This document; ShellCheck CI; release workflow disabled; README banner; smoke harness skeleton; synthetic fixture helper | CI green; harness runs and cleans up; nothing in `bin/aibox` changed yet |
| 2. Smallest useful core | Carved `bin/aibox`: private home, per-project network, labels, `up` (create and start only), `run`, `shell`, `stop`, `status`, `--dir`, `--env`, locking, session markers, readiness, stderr and exit-status rules, foreign-schema refusal | Reuse, concurrent commands, persistence, no unintended mounts, clean output, refusal of the v2 container, Linux ownership check |
| 3. Make changes dependable | Explicit replacement with rollback, refusal while active, fail-closed inspection, live limits with explicit clearing, `remove` and `--purge`, image fingerprint and `--rebuild`, custom-image validation, `port-forward` | Concurrent `run` plus `up`, replacement failure recovery, active-process and inspection-failure refusal, limits effective and cleared, forwards on loopback surviving replacement |
| 4. Validate everyday use | Execute [MILESTONE-4-VALIDATION.md](MILESTONE-4-VALIDATION.md): real agent and transport use, disconnect/restart behavior, v2 state-copy acceptance, Linux lifecycle, decision scorecard, README rewrite, publishing metadata retargeting, and historical-doc cleanup | Completed acceptance table with evidence; all success criteria in section 10 demonstrated; README matches observed behavior; size checkpoint resolved |

#### Milestone 1: settle the contract

Scope:

- This document, revised and committed.
- `.github/workflows/shellcheck.yml` running ShellCheck on `bin/aibox` and
  `scripts/*.sh`.
- The release workflow disabled (for example, its trigger changed to manual)
  so a pushed tag cannot attempt to publish to the original npm package or
  Homebrew tap.
- One banner line at the top of `README.md`: the README describes v2; the
  prototype is specified in `PROTOTYPE.md`.
- `scripts/smoke.sh` skeleton: scratch project creation, label-based cleanup,
  the `PASS`/`FAIL` reporter, the stub-`docker` mechanism, and a synthetic home
  fixture helper. No lifecycle tests yet.

Not in this milestone: any behavior change in `bin/aibox`.

Exit criteria:

- CI is green with ShellCheck passing on the current `bin/aibox` (add
  justified directives where the inherited code needs them).
- `scripts/smoke.sh` runs against the current CLI, reports zero checks, and
  leaves no resources behind.

#### Milestone 2: smallest useful core

Scope:

- Apply the deletions in section 4.3.
- Replace the slice mounts with one private named volume; create the
  per-project network; apply the labels of section 5.1.
- Leading `--dir` parsing; the unsafe-path list; rejection of remote Docker
  contexts.
- `up` limited to create and start. No replacement logic yet except the
  `Created`-state case.
- `run` with `--env` (bare-name forwarding; unset is an error); the
  program-not-found message; `shell` with the shell fallback.
- `stop` and `status` for this project and, without a project, for all schema-3
  sandboxes.
- Locking as specified in section 5.6: symlink mutex, session markers,
  fail-closed inspection, PID-based idle identification, entrypoint readiness
  marker. The mutex protects creation; markers are written even though nothing
  replaces yet, so milestone 3 inherits them.
- Foreign-schema refusal for containers, volumes, and networks.
- Notices to stderr; program exit status passthrough.
- The entrypoint reduced to mountpoint ownership, shell skeleton, and the
  readiness marker.
- Image build with the fingerprint label. The default image gains `tmux`.
- Stale-image notice from `run` and `shell`.

Exit criteria, each a smoke check unless marked manual:

- Two invocations in one project reuse one container, one volume, one network.
- Two concurrent `run` invocations on an absent sandbox produce exactly one
  container and both commands succeed.
- The container has exactly two mounts: the project bind at its host path and
  the home volume at `/home/aibox`.
- An unrelated host directory is not visible inside the sandbox.
- A file written to the home persists across `stop` and `run`; a package
  installed with `apt` persists across `stop` and `run`.
- `--dir` from elsewhere targets the same sandbox as running from the project.
- `run --env NAME` delivers the value; an unset name fails before any exec;
  the value appears nowhere in `status` or stderr.
- `aibox run sh -c 'echo out; echo err >&2; exit 7'` yields `out` on stdout
  only, the AI Box notices on stderr only, and exit status 7.
- Unsafe paths are rejected; the canonical error text is asserted.
- A container carrying the sandbox name without schema 3 is refused and left
  untouched (fixture: a plain container created by the test with that name).
- With the daemon endpoint made non-local through the stub, the CLI refuses.
- A stub `docker top` failure is reported as "cannot establish safety" by the
  idle check.
- The readiness marker appears without any agent installer present.
- Manual: on a Linux Docker Engine host, files created inside the sandbox are
  owned by UID 1000 on the host, and the limitation is documented.

#### Milestone 3: make changes dependable

Scope:

- The replacement procedure of section 5.5 in `up`, including rename-aside,
  stop-before-start, readiness wait, and rollback restoring the previous
  running or stopped state.
- Refusal of replace-class changes while sessions or processes are active, and
  on any inspection failure.
- Live limits through `docker update`, memory always paired with memory-swap,
  omitted flags preserving values, explicit clearing, verbatim reporting of a
  rejected update.
- `remove` and `remove --purge --yes`, with the retained-versus-deleted
  report.
- Fingerprint-driven rebuild, `up --rebuild`, and image comparison by ID.
- Custom-image validation of section 5.9.
- `port-forward` with its lifecycle integration into `stop`, `up`, `remove`,
  and `status`.
- Actionable errors for address-pool exhaustion and host port in use.

Exit criteria, each a smoke check unless marked manual:

- Concurrent `run` and `up --image <derivative>`: the `run` either completes
  in the old container before replacement or lands in the new one; no process
  is killed and no command fails with a missing-container error.
- Replacement with an image whose entrypoint exits non-zero fails, the old
  container is back under its name, and it is running if it was running before
  and stopped if it was stopped before.
- With a `tmux` server or a background `sleep` inside, `up --image` refuses
  and names the command to run after `stop`; with the stub `docker top`
  failing, it refuses with the inspection message.
- `up --cpus 1.5 --memory 256m --pids 50` changes the cgroup values read from
  inside the running container without a replacement; `up --pids 0` clears
  the process limit live; `up --cpus 0` is refused while active and performs a
  replacement when idle.
- `up` with no flags after `up --cpus 2` leaves the CPU limit at 2.
- `remove` leaves the volume and reports it; `remove --purge --yes` deletes
  it; the network and forwarders are gone in both cases.
- Editing `Dockerfile.extra` changes the fingerprint and `up` rebuilds and
  replaces; `run` only prints the stale-image notice.
- An image with a changed user or a non-passthrough entrypoint is rejected by
  `up --image` before the existing container is touched.
- `port-forward 18080:8080` to a server bound on the container interface is
  reachable at `127.0.0.1:18080`, the binding is loopback only, and it still
  works after `up --image` replaces the container without restarting the
  sidecar. A server bound only to the container's loopback produces the
  documented diagnosis.
- `stop` stops the sidecar; `up` restarts it; `port-forward --stop-all`
  removes all of this project's sidecars and no other project's.
- Manual: Docker Desktop restart brings the sandbox and its forwarders back.

#### Milestone 4: validate everyday use

Scope:

- Use [MILESTONE-4-VALIDATION.md](MILESTONE-4-VALIDATION.md) as the canonical
  manual procedure and evidence record for this milestone. A result is PASS,
  FAIL, BLOCKED, or EXPECTED LIMITATION; unavailable external prerequisites
  are not rewritten as successful AI Box behavior.
- A derivative image example in the README (`Dockerfile.extra`) that installs
  Claude Code and Codex outside the home directory, and a session of each
  through `aibox run`.
- Local Codex and Claude authentication, bounded project edits, exit, and
  session resume. Repeat against a second project to measure private-home login
  friction rather than assuming it is acceptable.
- Disconnect survival: start an agent under `tmux`, close the terminal, and
  reattach. Record separately that explicit container stop or Docker restart
  does not resurrect arbitrary `docker exec` processes.
- Transport composition: reach the host over SSH and enter the same sandbox
  with an ordinary AI Box command; drive Claude inside the sandbox through
  Claude Remote Control from another browser or phone. Codex Remote is an
  optional composition check and must not be described as automatically
  placing its host-side process inside AI Box.
- Real dev-server validation: bind on the container interface, reach it through
  the loopback-only forward, exercise HMR/WebSockets, and reach that host
  loopback from another device through an SSH tunnel.
- Host-availability validation: distinguish terminal disconnect, host sleep,
  explicit `aibox stop`, and Docker-daemon restart. Only the sandbox and
  forwarder definitions are expected to restart with Docker.
- The acceptance fixture: with the v2 container stopped, copy the developer's
  project home and transcripts from the sliced volume into the new per-project
  volume, chown at copy time, and confirm `claude --resume` lists the sessions.
  The v2 volume is not modified; the cleanup commands are printed, not run.
- The Linux lifecycle run: milestone 2 and 3 smoke checks on a Linux Docker
  Engine host.
- README rewritten from observed behavior, including the manual export and
  import procedure, the `cleanupPeriodDays` warning, the dev-server interface
  note, the address-pool note, and the security statement.
- `REVAMP.md` marked historical at its top. `CONTRIBUTING.md` updated (no
  `docker rmi` step; smoke and ShellCheck instructions).
- `package.json` repository, homepage, bugs, description, and `files`
  retargeted to the fork; the release workflow retargeted or removed.
- Complete the product-decision scorecard for private homes, writable binds,
  explicit forwarding, `tmux`, derivative images, resource controls, always-on
  host requirements, and transport neutrality.
- Resolve the section 9.1 size checkpoint. After milestone 3, `bin/aibox` is
  approximately 1,375 lines, which is well beyond the “over 800 means stop and
  reconsider” guide. Either simplify it in a focused pass or explicitly revise
  the guide with rationale before declaring the prototype done.

Exit criteria:

- Every required row in the validation playbook's final acceptance table is
  PASS, or an accepted limitation is recorded accurately in this document and
  the README. BLOCKED is not equivalent to PASS.
- Every success criterion in section 10 is demonstrated, by the smoke script
  where marked and manually otherwise, and the results are recorded in the
  milestone commit message or an attached validation record.
- The README contains no statement that the smoke script or a manual check
  contradicts.

### 9.4 Definition of done

The prototype is done when milestone 4's exit criteria hold, the core file is
within the size guide of section 9.1, no command outside section 5.7 exists,
and the three decisions in section 7 have been exercised through real use with
the observations recorded in this document's next revision.

## 10. Prototype success criteria

Each criterion names the milestone whose exit criteria demonstrate it.

1. Starting AI Box twice in the same project reuses one sandbox. (M2)
2. Two terminals can execute concurrently without a creation race. (M2)
3. Codex, Claude, or another installed CLI runs through the same generic
   `aibox run` path. (M4)
4. Disconnecting the controlling terminal leaves the sandbox available, and a
   `tmux` session inside it survives. (M4)
5. Stopping and restarting retains the project home and installed state. (M2)
6. Replacing the container for an image update retains the home volume and
   the previous settings. (M3)
7. The sandbox cannot read an unrelated host directory. (M2)
8. CPU, memory, and process limits are visible and effective; CPU and process
   limits change live without replacement. (M3)
9. No UI, relay, tunnel, or agent-specific session service is required. (M2)
10. A user can reach the host using a transport AI Box does not know about and
    enter the same sandbox with a normal AI Box command. (M4)
11. `--dir` targets the same sandbox as running from that project's canonical
    directory. (M2)
12. A derivative image can be selected without weakening persistence or
    mounting additional host paths, and an incompatible image is rejected
    before anything is touched. (M3)
13. Only explicitly named environment values enter the sandbox, and their
    values never appear in status or diagnostic output. (M2)
14. Missing-runtime, remote-context, unsafe-path, image, mount, and low-disk
    failures produce actionable messages without modifying the host. (M2, M3)
15. `port-forward` reaches a dev server on loopback only and keeps working
    after the project container is replaced, without restarting the
    sidecar. (M3)
16. A replace-class change requested while processes are active, or while
    safety cannot be established, is refused, not applied. (M3)
17. A failed replacement leaves the previous container in place under its name
    and in its previous state. (M3)
18. `remove` reports what is retained; `remove --purge` deletes the home volume
    only after confirmation. (M3)
19. A resource with the sandbox name but a foreign schema is never adopted,
    started, or removed. (M2)
20. Data copied from the v2 sliced volume into a per-project volume resumes in
    its agent. (M4)

## 11. Deferred questions

The prototype does not need to settle:

- A dedicated remote or mobile experience.
- A GUI business model.
- Shared-authentication adapters and their migration (section 6).
- Support for arbitrary, non-derivative container images.
- Disposable copies, worktrees, or one-container-per-task workflows.
- Automatic dev-server URLs and preview routing.
- Environment files or implicit provider-specific environment forwarding.
- Automatic refresh of the base image.
- Backups spanning every project.
- Stronger microVM-backed isolation.
- Windows and WSL.
- Team, fleet, or multi-user administration.

These should be considered only after the narrow execution layer is useful on
its own.
