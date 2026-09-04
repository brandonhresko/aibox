# AI Box Minimal Sandbox Prototype

## Status

This document defines the scope for the next AI Box prototype. It is a
planning document, not a description of the current implementation.

Revised 2026-09-04 after a review of the Claude revamp branch and a follow-up
discussion. For this branch it supersedes two settled decisions in `REVAMP.md`:
D5 (one global home volume sliced per project) and D9 (wildcard Caddy proxy).
`REVAMP.md` stays in the repository as the history of v2.

The prototype starts from the revamp branch and deliberately narrows the
product. Its purpose is to validate one layer well: a persistent, isolated local
execution environment for AI coding tools and ordinary development commands.

## Product boundary

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

The conceptual boundary in one line:

> AI Box preserves the environment. The agent preserves the conversation. The
> user's transport preserves access.

## Prototype goals

1. Start or recover one persistent sandbox for the current project.
2. Run any command inside that sandbox without agent-specific orchestration.
3. Keep the selected project writable while hiding the rest of the host
   filesystem by default.
4. Preserve the sandbox home across disconnects, stops, and container
   recreation.
5. Keep destructive lifecycle operations explicit.
6. Support practical CPU, memory, and process limits using Docker-native
   controls, changed live where Docker allows it.
7. Reach a dev server inside the sandbox from the host browser through an
   explicit, loopback-only forward that never restarts the sandbox.
8. Remain understandable enough that a user can inspect the generated Docker
   resources and know where work is running.
9. Allow callers to select a project directory and a compatible container image
   without changing directories or editing the project.
10. Forward host environment values only when the user names them explicitly.

## Explicit non-goals

The first prototype will not include:

- A web, desktop, or mobile UI.
- A hosted relay, account system, or remote-control protocol.
- SSH, VPN, Tailscale, or tunnel provisioning.
- Claude or Codex session-history parsing.
- Push notifications, approvals, task boards, or agent orchestration.
- Automatic worktree or pull-request management.
- Wildcard dev-server hostnames or a shared reverse proxy.
- Automatic installation of Docker, Homebrew, coding agents, or host services.
- Backup, restore, or CLI self-update commands.
- A claim that ordinary Docker containers are equivalent to microVM isolation.
- Cloud infrastructure provisioning.

The revamp's `serve`, `sessions`, and `rc-resume` functionality is therefore
outside the prototype core. It may later exist as a separate adapter or
integration, but it must not determine the core architecture.

## Implementation strategy

The prototype is a carve-down of the existing `bin/aibox`, not a rewrite. The
revamp's container core went through several review rounds and encodes Docker
behavior that must not be rediscovered. The following existing behavior is
retained:

- Docker readiness checks and auto-start of an installed but stopped runtime.
- Image availability check and the embedded Dockerfile build.
- Race-safe container creation using the `mkdir` lock.
- Recovery from containers wedged in the `Created` state.
- Normalization of stray `docker inspect` output.
- TTY allocation only when stdin and stdout are terminals.
- Container startup polling.
- Active-process detection before recreation.
- `--restart unless-stopped` and `--init` around `sleep infinity`.
- Same-path bind mounting of the project.
- Bash 3.2 compatibility: no associative arrays, no `mapfile`.
- The existing `run`, `shell`, `stop`, and `status` mechanics.

The following is removed in the first carve. All of it remains in Git history
and may return later as adapters or separately scoped features:

- `serve`, `sessions`, `rc-resume`, and the embedded UI payloads.
- Caddy generation, the shared proxy, and its lifecycle.
- The Claude installer in the entrypoint, the Claude-specific `settings.json`
  and `CLAUDE.md` edits, and the `claude`-default dispatch that turned
  `aibox --resume` into a Claude call.
- `--yolo` and `--copy`.
- The global volume-layout migration and `scripts/migrate-to-v2.sh`.
- `backup`, `restore`, `update`, and the npm update check.
- `ANTHROPIC_*` environment forwarding.

## Proposed architecture

### Sandbox identity

- One persistent sandbox per absolute project directory.
- Project identity is the canonical absolute path, symlinks resolved. The
  sandbox name is `aibox-<slug>-<hash>`: `<slug>` is the sanitized directory
  basename and `<hash>` is a prefix of the SHA-256 of the path.
- The project container and its private home volume share that name. Docker
  namespaces containers and volumes separately, so there is no conflict.
- Every Docker resource AI Box creates is labeled with the project path, slug,
  hash, and the CLI version that created it.
- Multiple terminals may execute commands in the same sandbox.
- Concurrent creation must be race-safe.
- Named instances and automatic task-level containers are deferred.

### Workspace exposure

- Mount only the selected project directory from the host by default.
- Mount it read/write at the same absolute path inside the container.
- Do not mount the host home directory or unrelated parent directories.
- Do not mount the Docker socket.
- Do not automatically mount host SSH keys, cloud credentials, Git
  configuration, or other dotfiles.
- A copied or ephemeral workspace mode is a later, separate capability.

The default sandbox protects the rest of the host; it does not protect the
selected project from intentional or accidental edits. Git remains the primary
recovery mechanism for project files.

### Persistent state

- Each project gets one ordinary named Docker volume as its private home,
  mounted at the container user's home directory.
- Agent credentials, shell configuration, caches, agent state, and
  user-installed tooling inside that home are opaque to AI Box.
- The home volume survives container recreation and is deleted only by
  `remove --purge`.
- Nothing is installed into the home directory at image-build time: the volume
  mounts over it and shadows the contents. Agent binaries belong in the image,
  installed outside the home directory. Only authentication and state belong in
  the home volume. An in-home Claude install measured roughly 650 MB; with a
  private home per project it would be duplicated and separately updated in
  every project.
- The core uses no `volume-subpath` mounts, helper containers, layout markers,
  or layout migration. This is a simplicity choice, not a compatibility one:
  every Docker Engine since 26 supports subpath mounts, and adapters may use
  them.
- The container definition supports a list of additional mounts, each a volume,
  an optional subpath, a destination, and a read-only flag. The first prototype
  creates only the private home entry. Docker orders nested mounts by
  destination depth, so a later entry may sit under an earlier one.
- The entrypoint fixes ownership of every mountpoint on each start, because
  Docker creates nested mountpoints root-owned. A recursive ownership pass over
  the whole home runs once per volume, recorded by a marker file, not on every
  start.
- Do not rely on the container writable layer for state that must survive an
  image update. `apt` installs persist across stop and start but reset on
  recreation; `~/.aibox/Dockerfile.extra` is the way to keep them.

This trades one-login-across-all-projects convenience for a simpler
agent-neutral boundary. Shared authentication is designed for below and
implemented later as opt-in adapters.

### Sandbox definition and change policy

The running container is the sandbox definition. `docker inspect` is the read
API: resource limits from `HostConfig`, the image by ID, mounts from the mount
list. Labels carry identity only, plus whether the image is the AI Box default
or user-supplied. Labels are immutable, so no live-updatable value is ever
stored in one. AI Box writes no per-sandbox definition file on the host.

Verified against Docker Desktop 29 on cgroup v2:

| Setting | Changes live? | Notes |
|---|---|---|
| CPU quota (`--cpus`) | Yes, raise or lower | Cannot be cleared once set. Removing the limit is a recreate, or set it to the host CPU count |
| Memory | Yes, only with `--memory-swap` passed alongside | Alone, the update is rejected. Swap is set equal to memory so the limit is real. Cannot be cleared live. Lowering below current use triggers reclaim or OOM, so warn first |
| Process limit | Yes, including clearing it | |
| Restart policy | Yes | |
| Image | No | Compared by image ID, not tag, so a rebuilt custom image or a dev-mode rebuild is detected |
| Mounts, including future shared-auth mounts | No | |
| Ports published on the project container | No | Never used: forwards are sidecars |
| Hostname, extra hosts, init, user, working directory, devices, GPU, labels | No | |

`docker update` also applies to stopped containers and takes effect at the next
start.

Policy:

- `run` and `shell` never change the definition. They ensure the container
  exists and is running. The one convergence they keep is the default image
  following the CLI version and `node_version`; it is deferred with a warning
  while processes are active, because that desired state is recomputed on every
  run.
- `up` with flags applies live-class changes immediately, running or stopped. A
  recreate-class change recreates the container only when no processes are
  active.
- A recreate-class change requested while processes are active is refused with
  the exact command to run after `stop`. It is not deferred: there is nowhere
  to remember the intent without a definition file.
- The active-process check is the existing one: `docker top` minus the idle
  process. Agents, dev servers, shells, and a `tmux` server all count as
  active.

Critical lifecycle invariant:

> AI Box may automatically start a stopped container. It must never
> automatically destroy a running container that has processes in it.

### Command interface

```text
aibox                                   # concise help plus this project's status; never launches an agent
aibox [--dir PATH] up [--image IMAGE] [--cpus N] [--memory SIZE] [--pids N]
aibox [--dir PATH] run [--env NAME]... <command> [arguments...]
aibox [--dir PATH] shell [command...]
aibox [--dir PATH] stop [--all]
aibox [--dir PATH] status
aibox [--dir PATH] remove [--purge]
aibox [--dir PATH] port-forward PORT|HOST_PORT:CONTAINER_PORT ...
aibox [--dir PATH] port-forward --list | --stop PORT | --stop-all
aibox version
aibox help
```

Parsing rules:

- Global flags are accepted only before the command word. `--dir` is the only
  global flag.
- `--image` and the resource flags belong to `up` only. On `run`, a differing
  image could only recreate silently, be ignored silently, or be deferred, and
  all three are wrong.
- `run` parses `--env` only between `run` and the program name. Everything from
  the program name on passes through verbatim. A `--` ends AI Box parsing.
- Unknown command: one-line error with a help hint, exit 1. No interactive
  prompts except the `remove --purge` confirmation.

`aibox run` is the fundamental agent-neutral operation. Examples include:

```sh
aibox run codex
aibox run claude
aibox run opencode
aibox run npm test
```

`--dir` selects the project without requiring the caller to `cd` first. This is
part of the core contract because scripts and user-chosen remote tools need a
stable way to target a project. AI Box canonicalizes the path before deriving
the sandbox identity and rejects dangerously broad targets: `/`, the user's home
directory, `/Users`, `/home`, `/Volumes`, `/mnt`, `/tmp`, `/var`, `/etc`,
`/usr`, `/opt`, `/private`, and any path containing `:`.

`up` creates or starts the sandbox without running anything, so a remote caller
can pre-warm a project before attaching, and it is where the image and resource
limits are set.

`stop` stops the container and this project's port forwards. `stop --all` stops
every AI Box container and sidecar.

`remove` stops and removes the container and this project's port forwards, and
states that the home volume is retained and how to delete it. `remove --purge`
also deletes the home volume, after confirmation.

If the requested program is not found inside the sandbox, `run` prints an
actionable message naming the two installation paths rather than a bare exit
127.

Agent shortcuts may eventually alias `aibox run`, but the core must not depend
on one agent's session format, remote-control service, or authentication layout.

### Image selection

- AI Box supplies a default image for the zero-configuration path:
  `node:<node_version>-bookworm` plus a small baseline. Node stays in the
  baseline because agent CLIs and MCP servers are overwhelmingly
  npm-distributed. `tmux` joins the baseline (see Agent sessions).
- `up --image IMAGE` selects a compatible existing image. The choice is recorded
  on the container: a label marks it user-supplied, so later runs do not replace
  it with the default when the CLI version changes. AI Box validates image names
  before passing them to Docker.
- A changed image recreates the container under the change policy above. An
  image change never deletes the home volume.
- Before creating a persistent container from a user-supplied image, `up`
  probes it with a throwaway run and fails with an actionable message if the
  contract below is not met.
- `~/.aibox/Dockerfile.extra` remains the primary escape hatch: appended to the
  generated Dockerfile, it is how language runtimes and coding agents are baked
  in so that they survive recreation.

Custom-image contract, to be settled and tested before `--image` is treated as
stable:

- User or UID discovery, and the resulting ownership of files written to the
  project bind mount and the private home.
- Home-directory discovery, since the private volume mounts there.
- Entrypoint handling: the image's entrypoint must pass the command through.
- Availability of a long-running idle command, and whether images without
  `sleep` are rejected or bootstrapped.
- Working-directory behavior: the project path.
- Shell fallback for `shell`: `zsh`, then `bash`, then `sh`.

### Agent installation

- The core image supplies a small, documented Linux development baseline.
- AI Box does not silently install or update a particular coding agent.
- Users install tools inside the persistent project home, or bake them into the
  image through `Dockerfile.extra`. Binaries baked into the image must live
  outside the home directory.
- Optional installation helpers or adapters must remain separable from the
  sandbox lifecycle.

### Environment forwarding

- Do not copy the host environment wholesale into the sandbox.
- Persisted login state inside the private project home is the preferred agent
  authentication path.
- `run --env NAME` forwards the value of a named exported host variable. AI Box
  passes the bare name to Docker; the Docker CLI reads the value from its own
  environment and sends it in the API request, so the value never appears in a
  process argument list. Verified.
- A named variable that is not set in the host environment is an error, not an
  empty string.
- Do not maintain provider-specific hard-coded lists such as only `ANTHROPIC_*`
  or `OPENAI_*`.
- Forwarded values are never printed in status, logs, or error messages. Names
  may be.
- Environment-file support is deferred until its path, storage, and accidental
  disclosure behavior are deliberately specified.

### Lifecycle invariants

- Exiting an agent or shell does not destroy the sandbox.
- Losing a local or remote connection does not stop the sandbox.
- `stop` preserves all persistent state.
- `remove` is explicit and clearly reports which state will be retained or
  deleted.
- Image changes never silently delete the project home volume.
- A change that requires recreation is refused, not applied, while processes are
  active.
- Two simultaneous invocations for one project converge on the same sandbox.
- No cleanup policy silently removes active project environments.
- Port forwards never restart the project container.

### Networking and dev-server access

- Normal outbound networking is available for model APIs, package registries,
  Git hosting, and development dependencies.
- All AI Box containers join one user-defined bridge network, `aibox`. It is
  load-bearing: container-name resolution between forwarders and project
  containers only works on a user-defined network.
- AI Box does not create a public listener, a remote ingress path, or an SSH
  server in any sandbox.
- Ports are never published on the project container itself. A published port
  is part of the container's creation configuration; adding one would require
  recreation, killing agents, dev servers, shells, and `tmux` sessions.

Dev-server access is an explicit forward through a small sidecar:

```text
Browser
  |
127.0.0.1:HOST_PORT on the host
  |
socat sidecar container (aibox network)
  |
project container:CONTAINER_PORT
```

- `aibox port-forward 5173` publishes `127.0.0.1:5173` and relays to the
  project container's port 5173. `8080:3000` maps different host and container
  ports. Several specs may be given at once.
- The sidecar runs a pinned `alpine/socat` image relaying to the project
  container by name. socat resolves the name per connection, so a project
  container recreated under the same name is reachable again with no sidecar
  restart. Verified.
- Loopback only. The user's chosen transport, for example an SSH local forward,
  may make that endpoint reachable elsewhere.
- Raw TCP relay: WebSocket-based hot reload needs no special handling, and the
  browser sends a plain `localhost` Host header, which dev servers with host
  allowlists accept.
- Sidecars are labeled with the project path, hash, host port, and container
  port, and are found by label, never by name prefix.
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
  Desktop or OrbStack on macOS, because it is what makes an always-on machine
  recover from a remote invocation. If the daemon does not come up within the
  wait, the error names the runtime and the command to start it. Installation
  is never attempted.

Codex Remote SSH or VS Code reaching the host does not automatically place their
processes inside AI Box. The prototype guarantees a stable CLI entrypoint.
Deeper one-click integrations can be adapters later.

### Agent sessions

- The core exposes `aibox run <program> [arguments]`. The agent owns its
  transcript format, resume identifiers, retention, remote-control
  registration, and background semantics. AI Box owns the environment the
  agent runs in.
- `tmux` is in the baseline image as the neutral way to keep an interactive
  program alive across an SSH or terminal disconnect. A `docker exec` session
  ends with its terminal; the container does not.
- Warning to document prominently: removing the Claude-specific entrypoint
  removes the `cleanupPeriodDays` setting that stopped Claude Code from deleting
  transcripts idle for 30 days. Persistent storage prevents Docker from
  discarding files; it cannot prevent an agent from deleting its own data.
  Users set this in the agent's own settings, and a Claude adapter may later do
  it for them.

### Resource controls

- Docker-native controls: CPU quota (`--cpus`), memory (`--memory`, with
  memory-swap set equal so the limit is real), and process count (`--pids`).
  Optional device or GPU access is off by default and deferred.
- Defaults: process limit 4096; CPU and memory unlimited unless configured.
  Global defaults live in `~/.aibox/config`; `up` flags override them for one
  sandbox.
- Limits are applied live through `docker update` wherever the table above
  allows.
- Disk usage is reported: the container's writable layer and the home volume
  size. Enforced disk quotas are deferred because their behavior varies by
  Docker runtime and host filesystem.
- AI Box does not write configuration into the project.

### Host state and configuration

```text
~/.aibox/
  config             # key=value: node_version, cpus, memory, pids
  Dockerfile         # generated at build (regenerated each build)
  Dockerfile.extra   # optional, user-authored
  .lock-*            # transient creation locks
```

There are no per-sandbox definition files and no per-project files. The
sandbox definition is the container (see above).

### Diagnostics and inspectability

- Verify that the Docker CLI exists and the daemon is reachable, auto-start an
  installed runtime, but never install host dependencies.
- Return actionable errors for a missing runtime, stopped daemon, incompatible
  image, unsafe project path, failed mount, insufficient disk space (v1's host
  disk check before builds is retained), a program not found in the sandbox,
  and a host port already in use.
- Label every Docker resource with its AI Box project identity and canonical
  host path.
- `aibox status` reports the project path, container name, image, lifecycle
  state, configured resource limits, current CPU and memory use, relevant disk
  usage, and active port forwards.
- Mount boundaries and forwarded environment variable names must be
  inspectable; secret values must not be displayed.
- A larger `doctor`, `disk`, `volumes`, `clean`, or `nuke` command family is not
  part of the first prototype.

### Security statement

The prototype's security promise is intentionally limited:

> Commands can control the selected project and their private container home,
> but cannot access the rest of the host filesystem unless the user explicitly
> grants additional access.

- Processes may have administrative privileges inside the container; the
  default image has passwordless sudo.
- Docker socket access, privileged host mode, broad host mounts, and automatic
  credential forwarding remain off by default.
- Network access to the host is on: `host.docker.internal` resolves to the
  host, and normal internet access is available. The promise is about the host
  filesystem, not the host network.
- On Linux hosts without user-namespace remapping, root inside the container is
  root on the bind-mounted project. Documentation must distinguish Docker's
  container boundary from stronger VM or microVM isolation.

### Initial host support

- Validate first on macOS with the currently supported Docker-compatible
  runtime.
- Validate the same lifecycle on one current Linux Docker Engine host before
  describing the prototype as suitable for an always-on development station.
- Defer Windows and WSL support until path, ownership, and lifecycle behavior is
  intentionally designed and tested.

## Shared authentication (later, as opt-in adapters)

Shared login matters: re-authenticating Claude, Codex, and Git in every project
becomes friction quickly. The prototype does not implement it, but must not
paint the design into a corner.

```text
Core:     one private project home volume
Optional: shared Claude authentication    (adapter)
          shared Codex authentication     (adapter)
          shared Git identity / dotfiles  (adapter)
```

The core understands additional persistent mounts. An adapter knows where its
agent stores authentication and which state is safe to share. Agent neutrality
means the core does not depend on any adapter; it does not forbid
agent-specific convenience.

What a focused spike must establish, Claude first, then Codex:

- Claude's config directory mixes shareable files (credentials, `.claude.json`,
  `settings.json`, plugins) with per-project state (`projects`,
  `history.jsonl`, `sessions`, `session-env`, `shell-snapshots`). A
  whole-directory mount shares too much. The adapter shape is "share the
  directory, carve these subdirectories back out as private", using subpath
  mounts or one extra private volume per carve-out.
- `.claude.json` is a single file holding global state, the OAuth account
  record, and the per-project settings map, and Claude Code rewrites it whole.
  Two sandboxes sharing it will overwrite each other's edits. Decide whether
  that is acceptable or whether only the credentials file is shared and the rest
  seeded.
- A possible zero-mount path: `claude setup-token` issues a long-lived token
  that Claude Code reads from `CLAUDE_CODE_OAUTH_TOKEN`. Forwarded through
  `--env` it needs no shared volume and has no concurrent-writer problem. Test
  this first. No equivalent is known for Codex subscription auth.
- Codex keeps `auth.json`, `config.toml`, `sessions/`, and `history.jsonl`
  under `CODEX_HOME` (default `~/.codex`). Confirm the layout and apply the same
  carve-out shape.

A future opt-in migration is small and never a global relayout:

1. Create a separate shared-auth volume.
2. Select an existing project's login as the seed.
3. Preserve the original private credentials.
4. Copy only adapter-owned authentication state.
5. Record the shared mount on the participating sandboxes.
6. Recreate participating containers under the change policy.
7. Leave the original per-project state intact until verification succeeds.

## Decisions to validate early

Three choices should be tested with users before becoming permanent:

1. Whether a private home per project is acceptable or repeated agent login is
   too much friction.
2. Whether a writable bind mount is the correct default or users expect the
   original project directory to be protected automatically.
3. Whether an explicit `port-forward` is acceptable in place of the automatic
   wildcard URLs the revamp had.

Other useful observations include which resource limits users understand,
whether custom images are sufficient for installing their preferred agents, and
whether `tmux` is enough for disconnect survival. The custom-image compatibility
contract and the minimum useful environment-forwarding interface must also be
proven before they are treated as stable public APIs.

## Selected ideas retained from the original main branch

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

## Implementation sequence

0. Prepare the acceptance fixture. Copy the existing project's home and
   transcripts from the v2 sliced volume into a new per-project volume using
   Docker alone, with the source mounted read-only. Nothing in the old volumes
   is modified or deleted; the user removes them after verification.
1. Update this document.
2. Carve the core out of `bin/aibox` by applying the deletions list.
3. Replace the slice mounts with one private named volume per project, with
   mountpoint ownership handled in the entrypoint.
4. Preserve the lifecycle, locking, restart, and recreation protections, and add
   the refuse-while-active rule.
5. Revive and harden `port-forward`.
6. Add `--dir`, `up`, `remove`, `remove --purge`, `run --env`, labels, resource
   controls with live update, richer `status`, the unsafe-path additions, and
   the program-not-found and port-in-use messages.
7. Define and test the custom-image contract and probe.
8. Add `scripts/smoke.sh` covering the success criteria mechanically, and
   ShellCheck in CI.
9. Validate: stop and start, Docker restart, image recreation, active-process
   refusal, port-forward survival across recreation, private-home persistence,
   the step 0 fixture resuming in its agent, and live limit changes.
10. Rewrite the README only after observed behavior matches this document. Mark
    `REVAMP.md` historical and update `package.json` files and description.

## Prototype success criteria

The prototype is successful when it can demonstrate all of the following:

1. Starting AI Box twice in the same project reuses one sandbox.
2. Two terminals can execute concurrently without a creation race.
3. Codex, Claude, or another installed CLI can run through the same generic
   `aibox run` path.
4. Disconnecting the controlling terminal leaves the sandbox available, and a
   `tmux` session inside it survives.
5. Stopping and restarting retains the project home and installed state.
6. Recreating the container for an image update retains the home volume.
7. The sandbox cannot read an unrelated host directory by default.
8. CPU, memory, and process limits are visible and effective, and CPU and
   process limits change live without recreation.
9. No UI, relay, tunnel, or agent-specific session service is required.
10. A user can reach the host using a transport AI Box does not know about and
    enter the same sandbox with a normal AI Box command.
11. `--dir` targets the same sandbox as running from that project's canonical
    directory.
12. A compatible custom image can be selected without weakening persistence or
    mounting additional host paths.
13. Only explicitly named environment values enter the sandbox, and their
    values never appear in status or diagnostic output.
14. Missing-runtime, unsafe-path, image, mount, and low-disk failures produce
    actionable messages without modifying the host automatically.
15. `port-forward` reaches a dev server from the host browser on loopback only,
    is not reachable on other interfaces, and keeps working after the project
    container is recreated without restarting the sidecar.
16. A recreate-class change requested while processes are active is refused,
    not applied.
17. `remove` reports what is retained; `remove --purge` deletes the home volume
    only after confirmation.
18. Data copied from a v2 sliced volume into a per-project volume resumes in
    its agent.

## Deferred questions

The prototype does not need to settle:

- A dedicated remote or mobile experience.
- A GUI business model.
- The shared-authentication adapters and their spike findings.
- Disposable copies, worktrees, or one-container-per-task workflows.
- Automatic dev-server URLs and preview routing.
- Environment files or implicit provider-specific environment forwarding.
- Backups spanning every project.
- Stronger microVM-backed isolation.
- Windows and WSL.
- Team, fleet, or multi-user administration.

These should be considered only after the narrow execution layer is useful on
its own.
