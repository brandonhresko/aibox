# Milestone 4 Validation Playbook

This is the manual acceptance plan for the AI Box minimal sandbox prototype.
It turns Milestone 4 of [PROTOTYPE.md](PROTOTYPE.md) into repeatable tests with
explicit pass criteria. It is intentionally separate from the README: the
README should be rewritten from the results of these tests, not from intended
behavior.

The playbook was written against the agent-neutral schema-3 CLI after
Milestone 3. Commands for external agents were checked against their official
documentation on 2026-09-04. Recheck the linked documentation if those tools
have changed before running the agent-specific sections.

Recommended execution order:

1. Commit this validation plan separately.
2. Run Phase A and resolve the CLI size checkpoint described in section 20.
   Decide whether to simplify the implementation or explicitly revise the
   original estimate before spending time on interactive validation.
3. Run the macOS/local phases B through K and fill in evidence as you go.
4. Run the sensitive v2 copy as a guided operation, then run the Linux phase
   when a suitable host is available.
5. Complete the decision scorecard and only then rewrite the README and close
   publishing metadata.

If code changes after any behavioral phase, rerun Phase A and every affected
manual test. Do not preserve a PASS result across a change that could alter it.

## 1. What Milestone 4 proves

Milestones 2 and 3 establish that the Docker mechanics work. Milestone 4 asks
whether the resulting product is useful in ordinary work:

1. Codex and Claude Code can be installed in a derivative image and launched
   through the same `aibox run` command.
2. Each agent can authenticate, edit the selected project, exit, and resume
   without losing its own state.
3. A terminal disconnect does not destroy the sandbox, and a process launched
   under `tmux` survives that terminal disconnect.
4. SSH can reach the host and enter the same sandbox without AI Box knowing
   anything about SSH.
5. Claude Remote Control can expose a Claude session running inside AI Box to
   another browser or phone without AI Box owning the remote protocol.
6. A real development server is reachable through an explicit loopback-only
   port forward, locally and through a user-created SSH tunnel.
7. The private-home, writable-project, explicit-forwarding, and `tmux`
   decisions are acceptable in actual use.
8. Existing v2 Claude state can be copied into the new per-project home and
   resumed without changing the source volume.
9. The same lifecycle and UID behavior work on a native Linux Docker Engine.
10. Public documentation and package metadata describe only demonstrated
    behavior and point only to this fork.

Passing this playbook does **not** mean AI Box implements SSH, Claude Remote
Control, a UI, a relay, or agent session management. Those products provide
access or conversation state; AI Box provides the persistent execution
environment they enter.

## 2. Expected behavior that is easy to misread

- Closing a terminal does not stop the container. However, an ordinary
  foreground process attached directly to that terminal can end when the
  terminal disappears. Use `tmux` when the process itself must survive.
- `aibox stop` deliberately stops the container. It also ends `tmux`, agent,
  and dev-server processes inside that container. Their files may persist,
  but the processes do not.
- Restarting Docker restarts containers and forwarders whose restart policy
  allows it. It does not resurrect arbitrary processes previously started
  with `docker exec`, including `tmux` sessions and dev servers.
- A sleeping computer is not an always-on server. When a laptop sleeps or its
  lid suspends it, local compute pauses. A dedicated station must remain
  powered, awake, online, and running Docker.
- Claude Remote Control keeps execution on the machine and uses Anthropic's
  outbound remote connection. It is not the same thing as SSH, and AI Box does
  not implement it.
- AI Box's forwarded dev port is bound to the host's `127.0.0.1`. A second
  device cannot browse it directly over the LAN. That device needs its own
  transport, such as an SSH local tunnel.
- The selected project is writable by the container. AI Box protects other
  host paths from being mounted; it does not protect the selected project from
  an agent's edits. Use a clean Git worktree or a throwaway repository.
- Each project currently has a private home. Agent logins are therefore
  expected to be repeated in a second project. Whether that friction is
  acceptable is one of the decisions this milestone must record.

## 3. Result vocabulary and stop conditions

Record each test as one of:

- **PASS**: the observed result matches every pass criterion.
- **FAIL**: AI Box behavior contradicts a pass criterion.
- **BLOCKED**: an external prerequisite is unavailable, such as no second
  device, no eligible Claude account, or no Linux host.
- **EXPECTED LIMITATION**: behavior matches an explicitly documented boundary,
  such as the host sleeping or a direct `docker exec` process ending after a
  Docker restart.

Stop the validation and preserve evidence if any test:

- modifies or deletes the old v2 `aibox-home` source volume;
- touches a foreign or non-schema-3 Docker resource unexpectedly;
- loses the prototype's private-home data after `stop`, `up`, or replacement;
- replaces a running sandbox while an agent, `tmux`, or dev server is active;
- exposes a forwarded port on an address other than `127.0.0.1`;
- prints an authentication token or secret in status or diagnostics; or
- changes host files outside the selected project or `~/.aibox`.

Do not “fix forward” and continue after one of these failures. Save the exact
command, stderr, `aibox status`, and relevant `docker inspect` output first.
Never paste credential-file contents into an issue or test report.

## 4. Test workspace and evidence record

Use a disposable Git repository or a clean worktree. Do not use the AI Box
repository itself for agent edit tests.

From the root of this repository, set these variables in the terminal that
will run the checks:

```sh
export AIBOX_REPO="$(pwd -P)"
export AIBOX_BIN="$AIBOX_REPO/bin/aibox"
export AIBOX_TEST_PROJECT="/absolute/path/to/a/throwaway-project"
```

Confirm the project path is specific and safe:

```sh
test -d "$AIBOX_TEST_PROJECT"
git -C "$AIBOX_TEST_PROJECT" status --short
mkdir -p "$AIBOX_TEST_PROJECT/.aibox-validation"
"$AIBOX_BIN" --dir "$AIBOX_TEST_PROJECT" status
```

Before the first test, record:

| Field | Value |
|---|---|
| Date and timezone | |
| Host OS and version | |
| CPU architecture | |
| Docker product and server version | |
| AI Box commit | |
| AI Box version output | |
| Test-project absolute path | |
| Codex version | |
| Claude Code version | |
| Local, LAN, VPN, or internet connection | |

For each test, save short evidence: the command, result, relevant version, and
one sentence about what happened. Screenshots are useful for mobile and remote
tests but are not required. Redact usernames, hostnames, addresses, repository
names, and session URLs before publishing the results.

## 5. Phase A: automated regression gate

Run this phase before interactive testing and again after any code change made
in response to a failed manual test.

### A1. Static checks

```sh
bash -n bin/aibox scripts/smoke.sh scripts/docker-stub.sh
shellcheck --shell=bash --severity=warning bin/aibox scripts/*.sh
git diff --check
```

Pass when all three commands exit zero. If ShellCheck is unavailable, record
the test as BLOCKED locally and require the GitHub ShellCheck workflow to pass.

### A2. Docker smoke suite

```sh
./scripts/smoke.sh
```

Pass when the final line reports zero failures and the script exits zero. Also
confirm that no `smk-` test containers, volumes, networks, or images remain.
The Milestone 3 baseline is 75 checks, but behavior and zero failures matter
more than freezing that count forever.

## 6. Phase B: build an agent derivative

`~/.aibox/Dockerfile.extra` is global user configuration, not a project file.
If it already exists, inspect it and merge these lines deliberately; do not
overwrite existing customization.

```dockerfile
RUN sudo npm install -g @openai/codex@latest @anthropic-ai/claude-code@latest \
 && codex --version \
 && claude --version
```

Build and select the derivative:

```sh
"$AIBOX_BIN" --dir "$AIBOX_TEST_PROJECT" up --rebuild
"$AIBOX_BIN" --dir "$AIBOX_TEST_PROJECT" run sh -c \
  'command -v codex; command -v claude; codex --version; claude --version'
```

Pass when:

- the build succeeds;
- both commands exist and print versions;
- both executable paths are outside `/home/aibox`; and
- `aibox status` reports a running, non-stale sandbox.

Why outside the home: the private volume covers `/home/aibox`. Binaries baked
there would reach only a brand-new empty volume and would not update existing
sandboxes. Authentication and session state belong in the home; image-managed
binaries do not.

Current vendor references:

- [Codex CLI](https://developers.openai.com/codex/cli)
- [Codex authentication](https://developers.openai.com/codex/auth)
- [Claude Code installation](https://code.claude.com/docs/en/installation)

## 7. Phase C: Codex inside AI Box

### C1. Authenticate

For a Docker or headless-style environment, device-code login is the preferred
first attempt:

```sh
"$AIBOX_BIN" --dir "$AIBOX_TEST_PROJECT" run codex login --device-auth
"$AIBOX_BIN" --dir "$AIBOX_TEST_PROJECT" run codex login status
```

Open the displayed link on the host or another device and enter the one-time
code. Device-code login may need to be enabled in ChatGPT security or workspace
settings. A normal browser callback can be awkward inside a container because
the callback listener's `localhost` is the container, not the host.

Pass when Codex reports the intended account or authentication method without
printing credential contents.

### C2. Perform a bounded edit

Start Codex through the generic path:

```sh
"$AIBOX_BIN" --dir "$AIBOX_TEST_PROJECT" run codex
```

Give it a tightly bounded task in the disposable repository:

```text
Report your current working directory. Create .aibox-validation/codex.txt
containing the words "codex ran inside aibox". Do not change anything else.
```

Pass when:

- Codex reports the exact host project path as its working directory;
- the file appears immediately on the host;
- `git status --short` shows only the expected test artifact; and
- AI Box did not add configuration files to the project on its own.

### C3. Exit and resume

Exit Codex normally, then run:

```sh
"$AIBOX_BIN" --dir "$AIBOX_TEST_PROJECT" run codex resume
```

Select the previous chat and ask it to state the validation phrase. Pass when
the previous conversation is available and Codex does not require another
login. Record where Codex says it stores credentials (`file`, `keyring`, or
`auto`) because a container usually cannot use the host OS keychain. Never
record the contents of `~/.codex/auth.json`.

## 8. Phase D: Claude Code inside AI Box

### D1. Authenticate and trust the workspace

```sh
"$AIBOX_BIN" --dir "$AIBOX_TEST_PROJECT" run claude
```

Use `/login` if needed and accept the workspace-trust prompt for the disposable
project. Pass when Claude opens in the exact project path and can inspect the
project without AI Box forwarding an implicit `ANTHROPIC_*` value.

### D2. Perform a bounded edit

Use this prompt:

```text
Report your current working directory. Create .aibox-validation/claude.txt
containing the words "claude ran inside aibox". Do not change anything else.
```

Pass under the same criteria as C2.

### D3. Exit and resume

Exit normally, then run:

```sh
"$AIBOX_BIN" --dir "$AIBOX_TEST_PROJECT" run claude --resume
```

Pass when the session appears and can be resumed without another login.

Record whether the agent's own settings define a transcript-retention policy.
The prototype no longer injects Claude's previous `cleanupPeriodDays` setting.
Persistent storage prevents Docker from discarding files, but it cannot stop
Claude Code from deleting its own old transcripts.

## 9. Phase E: persistence and replacement

### E1. Stop, start, and replace

First make sure no agent or `tmux` process is still active.

```sh
"$AIBOX_BIN" --dir "$AIBOX_TEST_PROJECT" run sh -c \
  'printf "persistent\n" > "$HOME/.aibox-m4-home"'
"$AIBOX_BIN" --dir "$AIBOX_TEST_PROJECT" run sudo \
  sh -c 'printf "writable-layer\n" > /opt/aibox-m4-layer'
"$AIBOX_BIN" --dir "$AIBOX_TEST_PROJECT" stop
"$AIBOX_BIN" --dir "$AIBOX_TEST_PROJECT" up
"$AIBOX_BIN" --dir "$AIBOX_TEST_PROJECT" run sh -c \
  'test -f "$HOME/.aibox-m4-home" && test -f /opt/aibox-m4-layer'
```

Pass when both files, both agent logins, and both resumable sessions survive
the stop/start.

Now replace the idle container:

```sh
"$AIBOX_BIN" --dir "$AIBOX_TEST_PROJECT" up --rebuild
"$AIBOX_BIN" --dir "$AIBOX_TEST_PROJECT" run sh -c \
  'test -f "$HOME/.aibox-m4-home" && test ! -e /opt/aibox-m4-layer'
```

Pass when private-home state and agent login/session state survive replacement,
while the ad hoc `/opt` writable-layer file disappears. Confirm Codex and
Claude can still resume. The disappearance is expected: durable system tooling
belongs in the derivative image.

### E2. Manual export and import

This validates the manual backup procedure that will replace the old `backup`
and `restore` commands in the README. The archive contains agent credentials
and must be treated like a secret.

Read the sandbox/volume name from `aibox status`, then set it explicitly:

```sh
export AIBOX_SANDBOX="<verified-sandbox-name-from-status>"
export AIBOX_BACKUP_DIR="$(mktemp -d)"
"$AIBOX_BIN" --dir "$AIBOX_TEST_PROJECT" stop
docker run --rm -v "$AIBOX_SANDBOX:/v:ro" \
  -v "$AIBOX_BACKUP_DIR:/out" alpine \
  tar czf "/out/${AIBOX_SANDBOX}.tgz" -C /v .
chmod 600 "$AIBOX_BACKUP_DIR/${AIBOX_SANDBOX}.tgz"
```

Check that the archive exists and is non-empty. For this disposable validation
home only, purge and recreate the volume:

```sh
"$AIBOX_BIN" --dir "$AIBOX_TEST_PROJECT" remove --purge --yes
"$AIBOX_BIN" --dir "$AIBOX_TEST_PROJECT" up
"$AIBOX_BIN" --dir "$AIBOX_TEST_PROJECT" stop
docker run --rm -v "$AIBOX_SANDBOX:/v" \
  -v "$AIBOX_BACKUP_DIR:/in:ro" alpine sh -c \
  'cd /v && tar xzf "/in/$1"' sh "${AIBOX_SANDBOX}.tgz"
"$AIBOX_BIN" --dir "$AIBOX_TEST_PROJECT" up
```

Pass when the home marker, both logins, and both resumable sessions return.
The container's previous image choice and limits are not restored by a home
archive; `remove` deliberately discards that container configuration. Keep the
archive until validation is complete, never commit or upload it, then delete it
from the host.

## 10. Phase F: disconnect survival with tmux

Start a named session:

```sh
"$AIBOX_BIN" --dir "$AIBOX_TEST_PROJECT" run tmux \
  new-session -s aibox-m4-disconnect
```

Inside tmux, run `date`, leave the shell open, and close the entire controlling
terminal window without first exiting tmux. From a new terminal:

```sh
"$AIBOX_BIN" --dir "$AIBOX_TEST_PROJECT" run tmux list-sessions
"$AIBOX_BIN" --dir "$AIBOX_TEST_PROJECT" run tmux \
  attach-session -t aibox-m4-disconnect
```

Pass when the same tmux session and terminal state return. While it is still
running, also verify that a replace-class operation refuses safely:

```sh
"$AIBOX_BIN" --dir "$AIBOX_TEST_PROJECT" up --rebuild
```

Pass when `up` refuses and tells you to stop active work. End the tmux session
normally before continuing:

```sh
"$AIBOX_BIN" --dir "$AIBOX_TEST_PROJECT" run tmux \
  kill-session -t aibox-m4-disconnect
```

## 11. Phase G: SSH as an independent transport

### G1. Direct SSH terminal

SSH is enabled and secured on the host, not inside the AI Box container. For
the first pass, test from another computer on the same trusted LAN. On macOS,
enable Remote Login; on Linux, configure the host's SSH server. Prefer SSH keys.
Do not expose Docker's socket or publish it over TCP.

From the second device:

```sh
ssh <host-user>@<host-address>
```

In that SSH shell, use absolute paths on the host:

```sh
export AIBOX_BIN="/absolute/path/to/aibox/bin/aibox"
export AIBOX_TEST_PROJECT="/absolute/path/to/the/test-project"
"$AIBOX_BIN" --dir "$AIBOX_TEST_PROJECT" status
"$AIBOX_BIN" --dir "$AIBOX_TEST_PROJECT" run sh -c \
  'pwd; printf "ssh reached aibox\n" > .aibox-validation/ssh.txt'
"$AIBOX_BIN" --dir "$AIBOX_TEST_PROJECT" shell
```

Pass when:

- SSH reaches the host account;
- AI Box reports the same sandbox and project path used locally;
- the test file appears on the host and local terminal immediately; and
- a shell, Codex, or Claude can be entered using the normal AI Box command.

Repeat the Phase F tmux disconnect test from the SSH session, disconnect the
SSH client, and reconnect. Pass when the tmux session survives. This
demonstrates the intended boundary: SSH transports a terminal to the host; AI
Box enters the environment.

For access away from the LAN, prefer a user-managed VPN or mesh network such
as Tailscale over directly exposing port 22. That setup is outside AI Box and
is not required to accept the prototype.

### G2. Optional Codex Remote connection

Current Codex clients can connect the ChatGPT desktop app to an SSH host; see
[OpenAI's Remote connections guide](https://learn.chatgpt.com/docs/remote-connections).
This is a useful optional composition test, but its boundary is subtle. A
remote Codex project normally starts Codex's app server on the SSH host. It
does not automatically move that Codex process into the AI Box container.
The official connection also requires `codex` to be installed and authenticated
on the host's login-shell `PATH`; that host installation is a transport
prerequisite distinct from the copy baked into the AI Box derivative.

After configuring the host according to the official guide, ask the remote
Codex session to run one explicit command:

```text
Run /absolute/path/to/aibox/bin/aibox --dir /absolute/path/to/project run
sh -c 'pwd; printf "codex remote called aibox\n" >
.aibox-validation/codex-remote.txt'. Do not change anything else.
```

Pass when the command enters the same schema-3 sandbox and the file appears.
Record this honestly as “Codex Remote can invoke AI Box on the host,” not
“Codex Remote automatically runs inside AI Box.” A deeper one-click launch
would be an adapter and is outside this prototype.

## 12. Phase H: real dev-server access

Use an actual test application if possible. Start its dev server under tmux
and make it listen on `0.0.0.0` inside the container. Adapt the command and
port to the framework:

```sh
"$AIBOX_BIN" --dir "$AIBOX_TEST_PROJECT" run tmux new-session \
  -s aibox-m4-dev 'npm run dev -- --host 0.0.0.0'
```

Detach with `Ctrl-b d`, then create the explicit forward. This example assumes
port 4173:

```sh
"$AIBOX_BIN" --dir "$AIBOX_TEST_PROJECT" port-forward 4173
"$AIBOX_BIN" --dir "$AIBOX_TEST_PROJECT" port-forward --list
curl http://127.0.0.1:4173
```

Open `http://127.0.0.1:4173` in the host browser. Pass when:

- the app loads;
- the Docker binding shown by the CLI is `127.0.0.1`, not all interfaces;
- a source edit appears through hot reload or a normal refresh;
- WebSockets/HMR work if the framework uses them; and
- creating the forward did not replace or restart the sandbox.

From a second computer, tunnel the host-loopback endpoint through SSH:

```sh
ssh -N -L 14173:127.0.0.1:4173 <host-user>@<host-address>
```

Open `http://127.0.0.1:14173` on that second computer. Pass when it reaches the
same app. This is deliberately two layers: AI Box forwards container to host
loopback; SSH forwards remote-device loopback to host loopback.

Also test the common error once by binding a server only to `127.0.0.1` inside
the container. The AI Box forward should not reach it, and the CLI guidance
should tell the user to bind the server to `0.0.0.0`.

End the dev-server tmux session and remove the forward before continuing:

```sh
"$AIBOX_BIN" --dir "$AIBOX_TEST_PROJECT" run tmux \
  kill-session -t aibox-m4-dev
"$AIBOX_BIN" --dir "$AIBOX_TEST_PROJECT" port-forward --stop 4173
```

## 13. Phase I: Claude Remote Control from a phone or browser

Check the current [Claude Remote Control documentation](https://code.claude.com/docs/en/remote-control)
first. It currently requires an eligible claude.ai login, workspace trust, and
an account or organization where Remote Control is enabled. It uses outbound
HTTPS and does not require an inbound host port.

Start the interactive Claude session inside tmux so the host terminal can
disconnect without ending Claude:

```sh
"$AIBOX_BIN" --dir "$AIBOX_TEST_PROJECT" run tmux new-session \
  -s aibox-m4-claude-remote \
  'claude --remote-control "AI Box validation"'
```

Open the displayed session URL or QR code from a phone or another browser.
Prefer testing once with the phone off the host's Wi-Fi so the result does not
depend on LAN reachability.

From the remote interface, ask Claude:

```text
Report your current working directory. Create
.aibox-validation/claude-remote.txt containing "remote control reached aibox".
Do not change anything else.
```

Pass when:

- the remote UI connects to the Claude process inside the AI Box sandbox;
- Claude reports the exact host project path;
- the file appears on the host immediately;
- permission prompts and responses work from the remote interface;
- closing and reopening the phone app reconnects; and
- closing the host terminal does not end Claude because tmux owns the process.

Reattach from the host if needed:

```sh
"$AIBOX_BIN" --dir "$AIBOX_TEST_PROJECT" run tmux \
  attach-session -t aibox-m4-claude-remote
```

Then end Claude normally and confirm `claude --resume` can recover its local
conversation. Record separately whether Remote Control reconnects; that part
belongs to Claude, while the persisted files and runnable environment belong
to AI Box.

Optional interruption check: briefly disconnect networking, then restore it.
Pass when Claude's Remote Control connection recovers without project or home
data loss. A sleeping host should show as unavailable until it wakes; that is
an EXPECTED LIMITATION, not an AI Box persistence failure.

## 14. Phase J: second-project isolation and login friction

Create or select a second disposable project and set:

```sh
export AIBOX_TEST_PROJECT_B="/absolute/path/to/a/second-throwaway-project"
"$AIBOX_BIN" --dir "$AIBOX_TEST_PROJECT_B" up
"$AIBOX_BIN" --dir "$AIBOX_TEST_PROJECT_B" run sh -c \
  'test ! -e "$HOME/.aibox-m4-home"'
"$AIBOX_BIN" --dir "$AIBOX_TEST_PROJECT_B" run codex login status
"$AIBOX_BIN" --dir "$AIBOX_TEST_PROJECT_B" run claude
```

Pass when the second project cannot see project A's home marker or transcripts.
Record whether Codex and Claude require another login, how long it takes, and
whether that feels acceptable. Do not “solve” the inconvenience by manually
sharing entire config directories: the point of this test is to gather evidence
for a later, narrowly designed shared-auth adapter.

## 15. Phase K: Docker restart and host availability

This is manual because restarting Docker can disrupt unrelated containers.
Inspect the daemon first and postpone the test if it would interrupt other
work.

1. Make sure the test sandbox is running.
2. Create one harmless port forward and record `aibox status` and
   `port-forward --list`.
3. End agent, tmux, and dev-server processes cleanly.
4. Restart Docker Desktop, OrbStack, Colima, or the Linux Docker daemon.
5. Wait for Docker to become ready.
6. Run `aibox status` and `port-forward --list` again.

Pass when the sandbox and forwarder definitions return in the running state,
the private-home marker remains, and the forward remains loopback-only. Do not
expect an earlier dev server or tmux process to return; restart it explicitly.

Separately test host sleep or laptop-lid behavior. Record how long the machine
is unavailable and whether the chosen transport reconnects after wake. For an
always-on station, record the actual power, sleep, network, and Docker-startup
settings required to keep that host available.

## 16. Phase L: v2 state-copy acceptance fixture

This is the only test involving real legacy credentials and transcripts. Run
it last, with a backup, and verify every Docker resource name before a write.
The prototype CLI must never perform this migration automatically.

The v2 source layout is expected to contain:

- `aibox-home/projects/<hash>/home` for the project's private home;
- `aibox-home/shared/claude-cfg` for shared Claude configuration; and
- `aibox-home/projects/<hash>/claude-projects` for project transcripts.

The schema-3 destination is the ordinary named volume printed as the sandbox
name by `aibox status`. The acceptance operation copies the project home into
the destination root, shared Claude configuration into `.claude`, and the
project transcript slice into `.claude/projects`, then recursively changes
the copied destination data to UID/GID 1000.

Before copying:

```sh
docker ps -a --filter label=aibox.layout=2 \
  --format '{{.ID}} {{.Names}} {{.Status}} {{.Label "aibox.path"}}'
docker ps --filter volume=aibox-home
"$AIBOX_BIN" --dir "$AIBOX_TEST_PROJECT" status
```

Required safeguards:

1. Canonicalize the project path and calculate its six-character SHA-256 path
   hash; compare it with both the v2 slice and schema-3 sandbox identity.
2. Stop the exact v2 project container and verify no running container mounts
   `aibox-home`.
3. Stop the schema-3 destination sandbox for a consistent copy.
4. Export the destination volume first using the manual backup command in
   `PROTOTYPE.md` section 5.3.
5. Mount `aibox-home` read-only in the copy helper. Never delete, rename,
   chown, or otherwise write the v2 source.
6. Copy into the destination volume and chown only the destination.
7. Save the exact cleanup commands for the old resources, but do not run them.

Calculate and display the identity without reading credential contents:

```sh
export AIBOX_CANONICAL_PROJECT="$(cd "$AIBOX_TEST_PROJECT" && pwd -P)"
export AIBOX_PROJECT_HASH="$(printf '%s' "$AIBOX_CANONICAL_PROJECT" \
  | shasum -a 256 | cut -c1-6)"
printf 'project=%s\nhash=%s\n' "$AIBOX_CANONICAL_PROJECT" "$AIBOX_PROJECT_HASH"
```

Because the source contains live credentials and the copy targets a populated
home, generate and review the exact `docker run` command from the verified
inventory instead of pasting an unverified one-liner from this document.

After copying:

```sh
"$AIBOX_BIN" --dir "$AIBOX_TEST_PROJECT" up
"$AIBOX_BIN" --dir "$AIBOX_TEST_PROJECT" run claude --resume
```

Pass when the expected v2 session appears and resumes under the same canonical
project path, the source volume remains read-only and its files remain
unchanged, and the recorded cleanup commands have not been executed. Record
collisions or missing sessions as failures; do not delete the source after a
partial result.

## 17. Phase M: native Linux acceptance

Run on a current Linux host using the native Docker Engine, not Docker Desktop
inside a VM.

Required checks:

1. Record the distribution, kernel, Docker server version, architecture, and
   host user's UID/GID.
2. Run the full smoke suite and require zero failures.
3. Repeat the derivative-image, Codex, Claude, stop/start, replacement, tmux,
   dev-server, and SSH checks.
4. Have the container create a file in the bind-mounted project, then inspect
   it on the host with `stat`.

```sh
"$AIBOX_BIN" --dir "$AIBOX_TEST_PROJECT" run sh -c \
  'printf "linux ownership\n" > .aibox-validation/linux-owner.txt'
stat -c '%u:%g %n' "$AIBOX_TEST_PROJECT/.aibox-validation/linux-owner.txt"
```

The expected owner is UID/GID 1000. If the host user is not UID 1000, record
the resulting usability problem explicitly. That is a documented prototype
limitation and must be visible in the README before Linux is advertised
broadly.

## 18. Optional endurance and substitution tests

These improve confidence but do not block the first prototype unless a failure
reveals data loss or a false product claim:

- Leave the host awake and a sandbox running for 24 hours; reconnect locally,
  through SSH, and through Claude Remote Control.
- Run a third agent such as OpenCode or Gemini CLI through `aibox run` using a
  derivative image. The invariant is the same generic entry path, not special
  AI Box support.
- Use VS Code Remote SSH or another terminal transport, then invoke the same
  AI Box commands on the host.
- Lower live CPU or memory limits during a real build and record whether the
  warnings and Docker errors are understandable.
- Run two agents concurrently in the same project and observe conflicts. They
  intentionally share one checkout and home; AI Box does not orchestrate them.
- Test SSH over a user-managed VPN from a different network.

Do not add a new transport, UI, provider adapter, or orchestration feature just
to make an optional substitution test pass.

## 19. Product-decision scorecard

Complete this after the tests. Concrete observations matter more than a simple
yes/no answer.

| Decision | Evidence to record | Accept, change, or defer |
|---|---|---|
| Private home per project | Number and duration of repeated Codex/Claude logins; whether sessions stayed isolated | |
| Writable project bind | Whether edits felt predictable; whether Git was sufficient recovery | |
| Explicit port forwarding | Commands required; framework friction; HMR/WebSocket result; SSH-tunnel experience | |
| `tmux` for disconnects | Whether starting, detaching, finding, and reattaching was understandable | |
| Derivative image setup | Build time; update experience; whether both agents stayed available after replacement | |
| Resource controls | Whether CPU, memory, and process settings and diagnostics were understandable | |
| Always-on host | Sleep, power, network, reboot, and Docker-startup requirements discovered | |
| Transport neutrality | Whether SSH and Claude Remote both entered the same environment without core changes | |

The most important output is whether private homes create unacceptable login
friction. If they do, the next work should be a separate, evidence-based auth
adapter spike—not a return to mounting whole agent configuration directories
across projects.

## 20. Documentation and release closure

Only after the behavioral tests are recorded:

- Rewrite `README.md` around observed schema-3 behavior and remove every v2
  claim about default Claude launch, shared sliced homes, wildcard Caddy URLs,
  `serve`, backup commands, disposable copies, and automatic migration.
- Include the derivative example, manual export/import, Claude transcript
  retention warning, `0.0.0.0` dev-server requirement, Docker address-pool
  diagnosis, Linux UID limitation, sleep/restart behavior, and narrow security
  statement.
- Mark `REVAMP.md` as historical and point readers to `PROTOTYPE.md`.
- Update `CONTRIBUTING.md` to use `up --rebuild`, the smoke suite, and
  ShellCheck; remove the manual `docker rmi` instruction.
- Retarget `package.json` repository, homepage, bugs, description, keywords,
  and published `files` to this fork and its actual contents.
- Remove or deliberately retarget the disabled release workflow. It must not
  reference the original npm ownership or `blitzdotdev/homebrew-tap`.
- Update `PROTOTYPE.md` status from planning-only language and record the three
  product decisions from section 19.
- Re-run static checks, the Docker smoke suite, and `npm pack --dry-run`.
- Confirm the packed archive contains only intended files and that no secret,
  test evidence, backup, session URL, or credential file is tracked.

Before calling the prototype done, also resolve the size checkpoint in
`PROTOTYPE.md` section 9.1. The post-Milestone-3 `bin/aibox` is approximately
1,375 lines, well above the document's “over 800 lines means stop and
reconsider” guide. This is not automatically a functional failure, but it is a
specification mismatch that needs an explicit decision or a focused
simplification pass before release.

## 21. Final acceptance table

| ID | Required result | Status | Evidence or blocker |
|---|---|---|---|
| A | Static checks and full smoke suite pass | | |
| B | Derivative provides Codex and Claude outside the home volume | | |
| C | Codex authenticates, edits only the requested file, exits, and resumes | | |
| D | Claude authenticates, edits only the requested file, exits, and resumes | | |
| E | Home/auth/session state survives stop/start and image replacement | | |
| E2 | Manual export, purge, import, and resume work without exposing the archive | | |
| F | A tmux-owned process survives terminal disconnection | | |
| G | SSH reaches the same sandbox through normal AI Box commands | | |
| H | Real dev server, HMR, loopback binding, and SSH tunnel work | | |
| I | Claude Remote reaches the sandbox from another device and reconnects | | |
| J | Second project is home-isolated and login friction is recorded | | |
| K | Docker restart restores sandbox and forwarder definitions | | |
| L | v2 state copy resumes the expected Claude session without source writes | | |
| M | Native Linux smoke/lifecycle passes and UID ownership is recorded | | |
| N | Product-decision scorecard is complete | | |
| O | README, historical docs, contribution guide, metadata, and release path match observed behavior | | |
| P | CLI size mismatch is simplified or explicitly accepted with rationale | | |

Milestone 4 is complete only when every required row is PASS, or an explicitly
accepted limitation is documented accurately in the README and
`PROTOTYPE.md`. External unavailability should remain BLOCKED rather than being
rewritten as success.

## 22. Cleanup after recording results

Cleanup applies only to the disposable projects and schema-3 resources created
for this playbook:

```sh
"$AIBOX_BIN" --dir "$AIBOX_TEST_PROJECT" port-forward --stop-all
"$AIBOX_BIN" --dir "$AIBOX_TEST_PROJECT" remove
"$AIBOX_BIN" --dir "$AIBOX_TEST_PROJECT_B" port-forward --stop-all
"$AIBOX_BIN" --dir "$AIBOX_TEST_PROJECT_B" remove
```

Plain `remove` intentionally retains each private-home volume. After reviewing
the results and any needed backup, delete only a validation home with:

```sh
"$AIBOX_BIN" --dir "$AIBOX_TEST_PROJECT" remove --purge --yes
"$AIBOX_BIN" --dir "$AIBOX_TEST_PROJECT_B" remove --purge --yes
```

Restore or remove the validation additions to `~/.aibox/Dockerfile.extra`
manually, preserving anything that existed before the test. Remove disposable
project directories only after checking their Git status and saving wanted
evidence. Never include the old v2 `aibox-home` volume in automated cleanup;
its removal is a separate, explicit post-migration decision.
