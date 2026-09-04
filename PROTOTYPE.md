# AI Box Minimal Sandbox Prototype

## Status

This document defines the proposed scope for the next AI Box prototype. It is a
planning document, not a description of the current implementation.

The prototype starts from the Claude revamp branch but deliberately narrows the
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

## Prototype goals

1. Start or recover one persistent sandbox for the current project.
2. Run any command inside that sandbox without agent-specific orchestration.
3. Keep the selected project writable while hiding the rest of the host by
   default.
4. Preserve the sandbox home and environment across disconnects, stops, and
   safe container recreation.
5. Keep destructive lifecycle operations explicit.
6. Support practical CPU and memory limits using Docker-native controls.
7. Remain understandable enough that a user can inspect the generated Docker
   resources and know where work is running.

## Explicit non-goals

The first prototype will not include:

- A web, desktop, or mobile UI.
- A hosted relay, account system, or remote-control protocol.
- SSH, VPN, Tailscale, or tunnel provisioning.
- Claude or Codex session-history parsing.
- Push notifications, approvals, task boards, or agent orchestration.
- Automatic worktree or pull-request management.
- Automatic wildcard domains or a shared Caddy proxy.
- A claim that ordinary Docker containers are equivalent to microVM isolation.
- Cloud infrastructure provisioning.

The current revamp's `serve`, `sessions`, and `rc-resume` functionality is
therefore outside the prototype core. It may later exist as a separate adapter
or integration, but it must not determine the core architecture.

## Proposed architecture

### Sandbox identity

- One persistent sandbox per absolute project directory.
- Project identity is a stable hash of the canonical absolute path.
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

- Give each project a private persistent home volume.
- Keep agent credentials, shell configuration, caches, and user-installed
  tooling opaque to AI Box.
- Preserve the home volume if the project container is recreated.
- Do not share agent-specific credential directories between projects in the
  first prototype.
- Do not rely on the container writable layer for state that must survive an
  image update.

This trades one-login-across-all-projects convenience for a simpler and safer
agent-agnostic boundary. Shared credentials can be evaluated later as an
explicit opt-in feature.

### Command interface

The core interface should remain small:

```text
aibox up
aibox run <command> [arguments...]
aibox shell
aibox stop
aibox status
aibox remove
```

`aibox run` is the fundamental agent-neutral operation. Examples include:

```sh
aibox run codex
aibox run claude
aibox run opencode
aibox run npm test
```

Agent shortcuts may eventually alias `aibox run`, but the core must not depend
on one agent's session format, remote-control service, or authentication layout.

### Agent installation

- The core image supplies a small, documented Linux development baseline.
- AI Box does not silently install or update a particular coding agent.
- Users may install tools inside the persistent project environment or build a
  custom image.
- Optional installation helpers or adapters must remain separable from the
  sandbox lifecycle.

### Lifecycle invariants

- Exiting an agent or shell does not destroy the sandbox.
- Losing a local or remote connection does not stop the sandbox.
- `stop` preserves all persistent state.
- `remove` is explicit and clearly reports which state will be retained or
  deleted.
- Image changes never silently delete the project home volume.
- Two simultaneous invocations for one project converge on the same sandbox.
- No cleanup policy silently removes active project environments.

### Networking

- Normal outbound networking is available for model APIs, package registries,
  Git hosting, and development dependencies.
- AI Box does not create a public listener or remote ingress path.
- AI Box does not install or manage an SSH server in each sandbox.
- Host port publication is explicit, local-only by default, and deferred unless
  it is required for the first validation workflow.
- Remote access reaches the host through the user's chosen tool, then invokes
  AI Box on that host.

### Resource controls

The prototype should use Docker-native controls for:

- CPU allocation, expressed as a CPU quota rather than an imprecise percentage.
- Memory limit.
- Process-count limit.
- Optional device or GPU access, disabled by default.

Disk usage should be reported. Enforced disk quotas are deferred because their
behavior varies by Docker runtime and host filesystem.

Resource settings belong to the sandbox definition and should remain stable
between invocations. Global defaults and command-line overrides are sufficient
for the prototype; AI Box should not write configuration into the project.

### Security statement

The prototype's security promise is intentionally limited:

> Commands can control the selected project and their private container home,
> but cannot access the rest of the host unless the user explicitly grants
> additional access.

Processes may have administrative privileges inside the container. Docker
socket access, privileged host mode, broad host mounts, and automatic credential
forwarding remain off by default. Documentation must distinguish Docker's
container boundary from stronger VM or microVM isolation, especially on Linux.

### Initial host support

- Validate first on macOS with the currently supported Docker-compatible
  runtime.
- Validate the same lifecycle on one current Linux Docker Engine host before
  describing the prototype as suitable for an always-on development station.
- Defer Windows and WSL support until path, ownership, and lifecycle behavior is
  intentionally designed and tested.

## Decisions to validate early

Two choices should be tested with users before becoming permanent:

1. Whether a private home per project is acceptable or repeated agent login is
   too much friction.
2. Whether a writable bind mount is the correct default or users expect the
   original project directory to be protected automatically.

Other useful observations include whether users need port publication in their
first session, which resource limits they understand, and whether custom images
are sufficient for installing their preferred agents.

## Prototype success criteria

The prototype is successful when it can demonstrate all of the following:

1. Starting AI Box twice in the same project reuses one sandbox.
2. Two terminals can execute concurrently without a creation race.
3. Codex, Claude, or another installed CLI can run through the same generic
   `aibox run` path.
4. Disconnecting the controlling terminal leaves the sandbox available.
5. Stopping and restarting retains the project home and installed state.
6. Recreating the container for an image update retains documented persistent
   state.
7. The sandbox cannot read an unrelated host directory by default.
8. CPU and memory limits are visible and effective.
9. No UI, relay, tunnel, or agent-specific session service is required.
10. A user can reach the host using a transport AI Box does not know about and
    enter the same sandbox with a normal AI Box command.

## Deferred questions

The prototype does not need to settle:

- A dedicated remote or mobile experience.
- A GUI business model.
- Shared authentication across projects.
- Disposable copies, worktrees, or one-container-per-task workflows.
- Automatic dev-server URLs and preview routing.
- Backups spanning every project.
- Stronger microVM-backed isolation.
- Team, fleet, or multi-user administration.

These should be considered only after the narrow execution layer is useful on
its own.
