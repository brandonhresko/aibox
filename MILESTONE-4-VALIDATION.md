# Milestone 4 Validation Playbook

This is the manual acceptance plan for the AI Box minimal sandbox prototype.
It turns Milestone 4 of [PROTOTYPE.md](PROTOTYPE.md) into repeatable tests with
explicit pass criteria. It is intentionally separate from the README: the
README should be rewritten from the results of these tests, not from intended
behavior.

This plan targets the agent-neutral schema-3 CLI after Milestone 3. It is a
procedure to execute, not a record that the current commits have passed an
audit or manual acceptance. The original playbook checked external-agent
commands against official documentation on 2026-09-04; recheck the linked
vendor documentation and the installed tool's help if an instruction differs.

## Start here: five phases

Use the phase letter for the overall activity and the step number for the
current check. For example, **B3.2** means Phase B, step 3, replacement check.
Run commands one block at a time and compare the result before continuing.
Do not paste the whole playbook into a terminal.

| Phase | Purpose | Steps | Ready to move on when… |
|---|---|---|---|
| [A — Prepare](#phase-a) | Establish the workspace, regression baseline, and agent image | [A1](#a1) workspace/evidence; [A2](#a2) regression and size checkpoint; [A3](#a3) image | The environment and versions are recorded and the baseline is usable |
| [B — Local use and persistence](#phase-b) | Prove both agents work and their data survives lifecycle changes | [B1](#b1) Codex; [B2](#b2) Claude; [B3](#b3) stop/start and replacement; [B4](#b4) backup recovery; [B5](#b5) second project | Local use, recovery, and private-home behavior have evidence |
| [C — Access and availability](#phase-c) | Exercise disconnects, remote access, dev servers, and Docker restart | [C1](#c1) tmux; [C2](#c2) SSH; [C3](#c3) dev servers; [C4](#c4) Claude Remote; [C5](#c5) host availability | Each access path and interruption has its own result |
| [D — Additional acceptance](#phase-d) | Validate Linux and the guided legacy-state copy | [D1](#d1) Linux; [D2](#d2) legacy migration; [D3](#d3) optional endurance/substitutions | Required external checks have evidence or explicit blockers |
| [E — Record and close](#phase-e) | Decide product tradeoffs, update docs, and clean up | [E1](#e1) scorecard; [E2](#e2) documentation; [E3](#e3) acceptance table; [E4](#e4) cleanup | Results and remaining limitations are accurately recorded |

Start on macOS with A, then B, then C. D1 needs a Linux host; D2 is a separate,
guided operation involving real legacy data and runs after disposable-project
tests. D3 is optional. An unavailable device or account can block one step
without preventing independent steps; leave that result BLOCKED and return to
it. E can record incomplete results, but cannot turn them into completion.

Keep this progress bookmark in a private copy of the playbook or your evidence
notes. The detailed [acceptance table](#e3) uses the same step IDs.

| Progress | Value |
|---|---|
| Current phase / step | A / A1 — not started |
| Last completed step and evidence path | |
| Next action | |
| Blocked steps and prerequisites needed | |
| Commit and image ID currently under test | |

If code changes after any behavioral step, rerun A2 and every affected manual
check. If the image or an agent version changes, record the new image ID and
versions and repeat affected agent/persistence checks. Do not carry a PASS
across a change that could invalidate it.

## What Milestone 4 proves

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

## Expected behavior that is easy to misread

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
  an agent's edits. Use a standalone disposable Git repository.
- Each project currently has a private home. Agent logins are therefore
  expected to be repeated in a second project. Whether that friction is
  acceptable is one of the decisions this milestone must record.

## Results and stop conditions

Record each test as one of:

- **NOT RUN**: no attempt has been made yet; the default for every step.
- **PASS**: the observed result matches every pass criterion.
- **FAIL**: an observed result contradicts a pass criterion. Record whether
  the cause is AI Box, the agent, the transport, or still unknown; a failed
  integration does not by itself identify an AI Box defect.
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
- makes an unexpected write outside the selected project or `~/.aibox`.
  Deliberate test setup, private evidence/backup files, and explicitly planned
  host operations are recorded separately from AI Box writes.

Do not “fix forward” and continue after one of these failures. Save the exact
command, stderr, `aibox status`, and relevant `docker inspect` output first.
Never paste credential-file contents into an issue or test report.

Use targeted `docker inspect --format` fields for IDs, mounts, labels, limits,
ports, and state. Avoid dumping full container environments into evidence.
Record expected nonzero results, such as active-process refusal or an
unauthenticated second project, against their stated criteria; they are not
automatically failed tests.

<a id="phase-a"></a>

## Phase A: Prepare the test environment

**Purpose:** establish a known baseline before interactive agent work.
**Needs:** this checkout, Docker, a disposable project, and private evidence storage.

<a id="a1"></a>

### A1. Test workspace and evidence record

Use a standalone disposable Git repository or clone, with its Git metadata
inside the selected directory. Prefer this over a linked worktree whose Git
metadata may be outside the one mounted path. Do not use the AI Box repository
itself for agent edit tests. The project should start clean; save its baseline
Git status before any agent task.

Have Docker running and leave enough disk space for image builds and a private
backup. Identify prerequisites now: both agent accounts for B, a second device
and host SSH for C2/C3, eligible Claude Remote access for C4, and a native Linux
Docker host for D1. Record missing prerequisites instead of discovering them
halfway through an unrelated test.

From the root of this repository, set these variables in the terminal that
will run the checks:

```sh
export AIBOX_REPO="$(pwd -P)"
export AIBOX_BIN="$AIBOX_REPO/bin/aibox"
export AIBOX_TEST_PROJECT="/absolute/path/to/a/throwaway-project"
export AIBOX_EVIDENCE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/aibox-m4-evidence.XXXXXX")"
```

Confirm the project path is specific and safe:

```sh
test -d "$AIBOX_TEST_PROJECT"
git -C "$AIBOX_TEST_PROJECT" status --short > "$AIBOX_EVIDENCE_DIR/baseline-status.txt"
cat "$AIBOX_EVIDENCE_DIR/baseline-status.txt"
mkdir -p "$AIBOX_TEST_PROJECT/.aibox-validation"
"$AIBOX_BIN" --dir "$AIBOX_TEST_PROJECT" status
```

Exported variables belong to this terminal; a new terminal or SSH session does
not inherit them. Record the resolved values privately and re-export the same
absolute paths after reconnecting. Reuse the original evidence directory;
rerunning `mktemp` creates another one. The SSH client uses paths on the host,
not paths on the second device. Never put credentials in a shell setup file.

Before the first test, record:

| Field | Value |
|---|---|
| Date and timezone | |
| Host OS and version | |
| CPU architecture | |
| Docker product, server version, active context, and endpoint | |
| AI Box commit and whether the checkout has uncommitted changes | |
| Image ID and sandbox container ID (fill after A3) | |
| AI Box version output | |
| Test-project absolute path | |
| Codex version | |
| Claude Code version | |
| Local, LAN, VPN, or internet connection | |

For each test, save short evidence: the command, result, relevant version, and
one sentence about what happened. Screenshots are useful for mobile and remote
tests but are not required. Redact usernames, hostnames, addresses, repository
names, and session URLs before publishing the results.

Keep evidence outside the agent-writable test project. A temporary directory is
convenient for this run; move wanted evidence to durable private storage before
cleanup. Fill agent versions after A3. Record each attempt separately:

| Step / substep | Host | Commit / image ID | Result | Expected / observed | Evidence or next action |
|---|---|---|---|---|---|
| Example: B3.2 | macOS | | NOT RUN | | |

Before each bounded agent edit, capture `git status --short --untracked-files=all`
and a diff; compare afterward. Earlier validation artifacts are expected to
remain, so check for **new changes relative to that baseline**, not an otherwise
empty Git status. A visible marker alone does not prove that nothing else changed.

<a id="a2"></a>

### A2. Regression gate and size checkpoint

Run this step before interactive testing and again after any code change made
in response to a failed manual test.

#### A2.1 Static checks

Run from `$AIBOX_REPO`; do not use an older globally installed `aibox`.

```sh
cd "$AIBOX_REPO"
(
  for AIBOX_CHECK_SCRIPT in bin/aibox scripts/smoke.sh scripts/docker-stub.sh; do
    bash -n "$AIBOX_CHECK_SCRIPT" || exit 1
  done
)
shellcheck --shell=bash --severity=warning bin/aibox scripts/*.sh
git diff --check
```

Pass when the syntax-check block, ShellCheck, and diff check each exit zero.
The loop is intentional: `bash -n file1 file2` checks only `file1`, treating
the remaining names as script arguments. If ShellCheck is unavailable, record
the test as BLOCKED locally and require the GitHub ShellCheck workflow to pass.

#### A2.2 Docker smoke suite

```sh
./scripts/smoke.sh
```

Pass when the final line reports zero failures and the script exits zero. Also
confirm the resources created by this run were cleaned up. Record any leftovers
by ID and label; do not delete resources just because their names contain
`smk-`, and do not run a daemon-wide prune or `stop --all`.
The Milestone 3 baseline is 75 checks, but behavior and zero failures matter
more than freezing that count forever.

Capture the smoke exit status as well as its summary. If saving output, redirect
it to a file and inspect that file afterward; a pipeline to `tee` without
`pipefail` can hide the smoke command's failing exit status.

#### A2.3 Record the size checkpoint decision

[PROTOTYPE.md section 9.1](PROTOTYPE.md#91-working-rules) treats passing 800 core
lines as a signal to reconsider. The post-Milestone-3 CLI was recorded at about
1,375 lines. Record the current count and the decision: a focused simplification
first, or explicit acceptance of the revised size with rationale. Do not turn
this validation run into an unplanned implementation audit or refactor. The
checkpoint must also be resolved in the final documentation at E2.

<a id="a3"></a>

### A3. Build and record the agent derivative

`~/.aibox/Dockerfile.extra` is global user configuration, not a project file.
If it already exists, inspect it and merge these lines deliberately; do not
overwrite existing customization. Save its original contents, or record that
it did not exist, in the private evidence directory so E4 can restore it.
Changes affect the default build for other projects on this host as well.

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

Record the installed agent versions and the image ID. For repeatable later
checks, replace `@latest` in the validation customization with those exact
versions and rebuild before recording the accepted image baseline. Record any
intentional version change during the run.

Read the sandbox name from `status` and save it for later checks:

```sh
export AIBOX_SANDBOX="<verified-sandbox-name-from-status>"
docker container inspect --format \
  '{{.Id}} {{.Image}} {{.State.StartedAt}} {{json .Mounts}}' "$AIBOX_SANDBOX"
docker volume inspect --format '{{json .Labels}}' "$AIBOX_SANDBOX"
```

Confirm the project bind and private home are the expected two mounts, and the
volume's schema/path labels identify this disposable project. Preserve these
IDs; later steps compare them instead of inferring replacement from a notice.

**Phase A checkpoint:** Record A1–A3 in E3. Start B with the verified image and project; do not infer a PASS from earlier milestone commits.

<a id="phase-b"></a>

## Phase B: Validate local use and persistence

**Purpose:** prove everyday agent work, exact-session resume, and recovery.
**Needs:** Phase A and agent accounts. B3/B4 depend on the sessions from B1/B2.
B4 deliberately purges only the disposable home after a checked export.

<a id="b1"></a>

### B1. Codex inside AI Box

#### B1.1 Authenticate

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

#### B1.2 Perform a bounded edit

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
- the before/after Git comparison shows only the requested new edit; and
- AI Box did not add configuration files to the project on its own.

#### B1.3 Exit and resume

Exit Codex normally, then run:

```sh
"$AIBOX_BIN" --dir "$AIBOX_TEST_PROJECT" run codex resume
```

Record the session identifier/title before exiting. Select that exact chat
and confirm prior turns are present in the transcript, then ask it to state
the validation phrase. Reading the marker file in a new chat alone is not
evidence of conversation resume. Pass when
the previous conversation is available and Codex does not require another
login. Record where Codex says it stores credentials (`file`, `keyring`, or
`auto`) because a container usually cannot use the host OS keychain. Never
record the contents of `~/.codex/auth.json`.

<a id="b2"></a>

### B2. Claude Code inside AI Box

#### B2.1 Authenticate and trust the workspace

```sh
"$AIBOX_BIN" --dir "$AIBOX_TEST_PROJECT" run claude
```

Use `/login` if needed and accept the workspace-trust prompt for the disposable
project. Pass when Claude opens in the exact project path and can inspect the
project without AI Box forwarding an implicit `ANTHROPIC_*` value.

#### B2.2 Perform a bounded edit

Use this prompt:

```text
Report your current working directory. Create .aibox-validation/claude.txt
containing the words "claude ran inside aibox". Do not change anything else.
```

Pass under the same criteria as B1.2, comparing against the current Git
baseline so the earlier Codex artifact is not mistaken for an extra edit.

#### B2.3 Exit and resume

Exit normally, then run:

```sh
"$AIBOX_BIN" --dir "$AIBOX_TEST_PROJECT" run claude --resume
```

Record the session identifier/title before exiting. Pass when that exact
session appears, its prior turns are present, and it resumes without another
login. Re-reading a project file from a new conversation is not sufficient.

Record whether the agent's own settings define a transcript-retention policy.
The prototype no longer injects Claude's previous `cleanupPeriodDays` setting.
Persistent storage prevents Docker from discarding files, but it cannot stop
Claude Code from deleting its own old transcripts.

<a id="b3"></a>

### B3. Stop/start and image replacement

#### B3.1 Stop and start

First exit both agents and make sure no `tmux` process or dev server is still
active. Record the container ID and image ID from A3 again before starting.

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

#### B3.2 Replace the idle container

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

Use the same inspect fields as A3 after each operation. Stop/start must retain
the container ID; `up --rebuild` must produce a different container ID even if
the image build reuses cached layers. Compare the home marker's contents, not
only its existence. After both operations, select the exact sessions recorded
in B1/B2 and verify the prior turns and authentication state.
Exit resumed agents before the next operation. After each intentional
replacement, update the progress bookmark with the new container/image IDs;
later steps compare against that current baseline, not the original A3 ID.

<a id="b4"></a>

### B4. Manual export and import

This validates the manual backup procedure that will replace the old `backup`
and `restore` commands in the README. The archive contains agent credentials
and must be treated like a secret.

Read the sandbox/volume name from `aibox status`, then set it explicitly:

```sh
export AIBOX_SANDBOX="<verified-sandbox-name-from-status>"
export AIBOX_BACKUP_DIR="$(mktemp -d)"
"$AIBOX_BIN" --dir "$AIBOX_TEST_PROJECT" stop
(
  umask 077
  docker run --rm -v "$AIBOX_SANDBOX:/v:ro" alpine tar czf - -C /v . \
    > "$AIBOX_BACKUP_DIR/${AIBOX_SANDBOX}.tgz"
)
```

Require the export command to exit zero; stop if it fails. Check the archive
before any purge:

```sh
test -s "$AIBOX_BACKUP_DIR/${AIBOX_SANDBOX}.tgz"
gzip -t "$AIBOX_BACKUP_DIR/${AIBOX_SANDBOX}.tgz"
tar tzf "$AIBOX_BACKUP_DIR/${AIBOX_SANDBOX}.tgz" >/dev/null
```

All three commands must succeed. Verify the volume's schema/path labels again
and confirm this is project A's disposable home, never the D2 legacy destination.
For this disposable validation home only, purge and recreate the volume:

```sh
"$AIBOX_BIN" --dir "$AIBOX_TEST_PROJECT" remove --purge --yes
"$AIBOX_BIN" --dir "$AIBOX_TEST_PROJECT" up
"$AIBOX_BIN" --dir "$AIBOX_TEST_PROJECT" stop
docker run --rm -i -v "$AIBOX_SANDBOX:/v" alpine tar xzf - -C /v \
  < "$AIBOX_BACKUP_DIR/${AIBOX_SANDBOX}.tgz"
```

Check that extraction exited zero before continuing:

```sh
"$AIBOX_BIN" --dir "$AIBOX_TEST_PROJECT" up
```

Pass when the home marker, both logins, and both resumable sessions return.
The container's previous image choice and limits are not restored by a home
archive; `remove` deliberately discards that container configuration. Keep the
archive until validation is complete, never commit or upload it, then delete it
from the host.

The archive is written by the host shell with private permissions, avoiding a
root-owned host archive on native Linux. Record the helper image ID used. This
procedure restores into a freshly initialized disposable home; it is not a
merge recipe for an existing populated home. Require extraction to exit zero
before starting the sandbox, then verify the exact prior sessions from B1/B2.

<a id="b5"></a>

### B5. Second-project isolation and login friction

Create or select a second standalone disposable project. Complete A3 first so
both agents are available from the default derivative. Use a fresh private
home for B; if its volume already contains an old login, select another
throwaway path rather than deleting an unknown home. Then set:

```sh
export AIBOX_TEST_PROJECT_B="/absolute/path/to/a/second-throwaway-project"
"$AIBOX_BIN" --dir "$AIBOX_TEST_PROJECT_B" up
"$AIBOX_BIN" --dir "$AIBOX_TEST_PROJECT_B" run sh -c \
  'test ! -e "$HOME/.aibox-m4-home"'
"$AIBOX_BIN" --dir "$AIBOX_TEST_PROJECT_B" run codex login status
```

Before logging in to B, inspect its mount list as in A3 and confirm it uses a
different home volume and project network. Repeat B1.1 and B2.1 using
`AIBOX_TEST_PROJECT_B` to authenticate each agent in this second project.
Check the agent resume pickers for the known A session identifiers from B1/B2;
they must not appear. An absent home marker alone does not establish transcript
separation. For each agent, create one bounded conversation, exit, and resume
it to establish B has its own usable state. End both agents before continuing.

Pass when the second project cannot see project A's home marker or transcripts.
Record whether Codex and Claude require another login, how long it takes, and
whether that feels acceptable. Do not “solve” the inconvenience by manually
sharing entire config directories: the point of this test is to gather evidence
for a later, narrowly designed shared-auth adapter.

Treat an unauthenticated `codex login status` exit as expected at this point,
not as a failure. If any test will deliberately share a token later, record
that separately; shared credentials would invalidate this login-friction test.

**Phase B checkpoint:** Record B1–B5, retain the original session identifiers and home marker, and exit all agent/tmux processes before C.

<a id="phase-c"></a>

## Phase C: Validate access and host availability

**Purpose:** distinguish terminal survival, remote reachability, and runtime recovery.
**Needs:** Phase B. C2/C3 require a second device and host SSH; C4 needs
eligible Claude Remote access. C5 requires a planned Docker interruption.
C1 and the local portion of C3 can proceed while remote prerequisites are blocked.

<a id="c1"></a>

### C1. Disconnect survival with tmux

Start a named session:

```sh
"$AIBOX_BIN" --dir "$AIBOX_TEST_PROJECT" run tmux \
  new-session -s aibox-m4-disconnect
```

Inside tmux, run `date`, leave the shell open, and close the entire controlling
terminal window without first exiting tmux. From a new terminal, re-export the A1 variables using the same paths, then:

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

Pass when `up` refuses and tells you to stop active work, the original
container ID is unchanged, and the tmux session remains usable. End the tmux session
normally before continuing:

```sh
"$AIBOX_BIN" --dir "$AIBOX_TEST_PROJECT" run tmux \
  kill-session -t aibox-m4-disconnect
```

<a id="c2"></a>

### C2. SSH as an independent transport

#### C2.1 Direct SSH terminal

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
- AI Box reports the same container ID and project path used locally;
- the test file appears on the host and local terminal immediately; and
- a shell, Codex, or Claude can be entered using the normal AI Box command.

Repeat the C1 tmux disconnect test from the SSH session, disconnect the
SSH client, and reconnect. Pass when the tmux session survives. This
demonstrates the intended boundary: SSH transports a terminal to the host; AI
Box enters the environment.

For access away from the LAN, prefer a user-managed VPN or mesh network such
as Tailscale over directly exposing port 22. That setup is outside AI Box and
is not required to accept the prototype.

#### C2.2 Optional Codex Remote connection

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

<a id="c3"></a>

### C3. Real dev-server access and forwarder continuity

#### C3.1 Start the app and verify the local forward

Use an actual test application in the disposable project. If it currently
contains only validation markers, prepare a small application before this step
and record its framework/version and start command. A placeholder project
without a dev script cannot satisfy this test. Start its dev server under tmux
and make it listen on `0.0.0.0` inside the container. Adapt the command and
port to the framework; the example below is for a script that accepts
`--host` and `--port`, and uses 4173 explicitly:

```sh
"$AIBOX_BIN" --dir "$AIBOX_TEST_PROJECT" run tmux new-session \
  -s aibox-m4-dev 'npm run dev -- --host 0.0.0.0 --port 4173'
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

Before and after creating the forward, compare the sandbox container ID and
`StartedAt` using A3's inspect fields. Both must stay unchanged.

#### C3.2 Verify LAN refusal and SSH-tunnel access

From a second computer on the same LAN **without a tunnel**, attempt to reach
`http://<host-LAN-address>:4173` with a short timeout. It must not serve the app.
Record both the Docker loopback binding and this actual negative reachability
check; either alone is incomplete evidence of the intended behavior. If no
second device is available, mark this subcheck BLOCKED.

Then tunnel the host-loopback endpoint through SSH:

```sh
ssh -N -L 127.0.0.1:14173:127.0.0.1:4173 <host-user>@<host-address>
```

Open `http://127.0.0.1:14173` on that second computer. Pass when it reaches the
same app. This is deliberately two layers: AI Box forwards container to host
loopback; SSH forwards remote-device loopback to host loopback.

#### C3.3 Keep the forwarder through replacement

Keep the forwarder while checking replacement once:

1. Record its container ID from the verified project/role labels.
2. End the dev-server tmux session, leaving the forwarder running.
3. Run `up --rebuild` while the project is idle.
4. Restart the same dev-server command in a new tmux session.
5. Confirm the app and HMR work again, the project container ID changed, and
   the forwarder's container ID did not. Existing TCP connections may drop;
   successful new connections are the criterion.

#### C3.4 Diagnose a container-loopback server and clean up

Also test the common error once by binding a server only to `127.0.0.1` inside
the container. The AI Box forward should not reach it, and the forward-creation guidance
should tell the user to bind the server to `0.0.0.0`.

For the loopback-only negative check, stop the `0.0.0.0` server first so it
cannot accidentally satisfy the request. Restore the working server afterward
if needed. Close the SSH tunnel with Ctrl-C on the second computer.

End the dev-server tmux session and remove the forward before continuing:

```sh
"$AIBOX_BIN" --dir "$AIBOX_TEST_PROJECT" run tmux \
  kill-session -t aibox-m4-dev
"$AIBOX_BIN" --dir "$AIBOX_TEST_PROJECT" port-forward --stop 4173
```

<a id="c4"></a>

### C4. Claude Remote Control from a phone or browser

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

Then end Claude normally (and any remaining named tmux session) and confirm `claude --resume` can recover its local
conversation. Record separately whether Remote Control reconnects; that part
belongs to Claude, while the persisted files and runnable environment belong
to AI Box.

Optional interruption check: briefly disconnect networking, then restore it.
Pass when Claude's Remote Control connection recovers without project or home
data loss. A sleeping host should show as unavailable until it wakes; that is
an EXPECTED LIMITATION, not an AI Box persistence failure.

<a id="c5"></a>

### C5. Docker restart and host availability

#### C5.1 Docker-daemon restart

This is manual because restarting Docker can disrupt unrelated containers.
Inspect the daemon first and postpone the test if it would interrupt other
work.

1. Make sure the test sandbox is running.
2. Create one harmless port forward and record `aibox status` and
   `port-forward --list`.
3. End agent, tmux, and dev-server processes cleanly.
4. Restart Docker Desktop, OrbStack, Colima, or the Linux Docker daemon.
5. Wait for Docker to become ready.
6. Before any `up`, `run`, or `shell` command can start resources for you,
   inspect the recorded sandbox and forwarder directly with Docker. Record
   their IDs, `State.Status`, `State.StartedAt`, and restart policies.
7. Run `aibox status` and `port-forward --list` again.

Pass when the sandbox and forwarder definitions return in the running state,
their IDs are unchanged, the private-home marker remains, and the forward
remains loopback-only. Inspect running state before using `run` to check the
marker; otherwise the command can hide a failure to restart automatically. Do not
expect an earlier dev server or tmux process to return; restart it explicitly.

Restart the dev server explicitly and verify an HTTP request through the
retained forward, then end that server before leaving this substep.

Record whether the runtime actually restarted containers or preserved them
through a live-restore mechanism. Do not generalize one runtime's result to
another.

#### C5.2 Sleep and wake

Separately test host sleep or laptop-lid behavior. Record how long the machine
is unavailable and whether the chosen transport reconnects after wake. For an
always-on station, record the actual power, sleep, network, and Docker-startup
settings required to keep that host available.

#### C5.3 Host reboot (only if claiming reboot recovery)

If documenting automatic recovery after a full **host reboot**, test that
separately in a planned interruption window and record whether host login or
manual Docker startup was necessary. A Docker-daemon restart or a sleep/wake
test alone does not establish reboot recovery. Otherwise leave that claim
unvalidated in the README.

**Phase C checkpoint:** Record C1–C5 separately, including local versus remote subchecks. End test sessions and tunnels; leave unavailable prerequisites BLOCKED.

<a id="phase-d"></a>

## Phase D: Validate additional hosts and legacy data

**Purpose:** extend the evidence to Linux and the real legacy migration.
**Needs:** completed disposable-project checks. D1 and D2 are independent;
D2 uses a separate inventory and guided transition, never the disposable
cleanup variables. D3 remains optional.

<a id="d1"></a>

### D1. Native Linux acceptance

Run on a current Linux host using the native Docker Engine, not Docker Desktop
inside a VM.

Required checks:

1. Record the distribution, kernel, Docker server version, architecture, and
   host user's UID/GID.
2. Run the full smoke suite and require zero failures.
3. Use the same AI Box commit, record any architecture-specific image ID, and
   repeat A3, B1–B5, C1, C2.1, C3, and C5 with Linux-specific evidence.
   Re-export all A1 variables for paths on this host; do not reuse macOS paths.
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

Also verify the host user can edit and remove the test file without an
unexpected permission workaround. Record rootless Docker or user-namespace
remapping if enabled: UID 1000 is the baseline expectation for the supported
unmapped setup, not a claim that every daemon maps ownership identically.
If these configurations are not tested, say so. Missing Linux access remains
BLOCKED even when the macOS run passes.

<a id="d2"></a>

### D2. Guided v2 state-copy acceptance fixture

This is the only test involving real legacy credentials and transcripts. Run
it after the disposable-project checks, with a backup, and verify every Docker
resource name before a write. It may run while D1 awaits a Linux host, but it
is never a substitute for Linux acceptance.
The prototype CLI must never perform this migration automatically.

Use a separate inventory and variables for this operation. **Do not reassign
`AIBOX_TEST_PROJECT`, `AIBOX_TEST_PROJECT_B`, or `AIBOX_SANDBOX` to the legacy
project**: E4 uses those names to clean up disposable resources.

```sh
export AIBOX_LEGACY_PROJECT="<verified-original-project-absolute-path>"
export AIBOX_LEGACY_CONTAINER="<verified-v2-container-name>"
export AIBOX_LEGACY_DESTINATION="<verified-schema-3-destination-name>"
```

This must be the original canonical project path whose sessions are being
resumed. The throwaway project from A1 normally has no corresponding v2 slice.
Changing the path changes the sandbox identity and can change agent session
discovery; do not silently turn this into a session-path migration test.

The old container may occupy the exact name needed by the new schema. Before
using the prototype CLI at this path, plan how to free the canonical name while
retaining the stopped v2 container and its writable layer, for example a
verified reversible rename. Record the original ID/name/state and the undo
procedure; do not remove the original to get past a schema refusal. A refusal
before the planned transition is expected protection, not a failed migration.

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
docker container inspect --format \
  '{{.Id}} {{.Name}} {{.State.Status}} {{json .Mounts}}' "$AIBOX_LEGACY_CONTAINER"
```

Required safeguards:

1. Canonicalize the original project path and calculate its six-character
   SHA-256 path hash; compare it with the actual v2 mounts, slice, and planned
   schema-3 identity. Verify every source subdirectory exists before copying.
2. Record all running consumers of `aibox-home`. Stop those exact consumers in
   a planned window and verify none remains running; the shared source may
   serve more projects than the one being copied. Do not use `stop --all`.
3. Resolve the old-container name collision with the recorded reversible
   procedure, create/select the verified schema-3 destination, and stop it for
   a consistent copy. Verify its schema/path labels and ordinary home mount.
4. Take a checked export of the stopped source and destination using the B4
   export pattern with separately verified legacy volume names. Keep archives
   outside all project directories with private permissions. Check command
   exit statuses and archive integrity before any destination write.
5. Mount `aibox-home` read-only in the copy helper. Never delete, rename,
   chown, or otherwise write the v2 source.
6. Review the copy map and collisions before extraction. The shared config
   slice can contain state from other projects: decide which files are needed
   and exclude unrelated history rather than blindly duplicating it. Check
   each copy command's exit status; chown only the copied destination.
7. Save the exact cleanup commands for the old resources, but do not run them.

Calculate and display the identity without reading credential contents:

```sh
export AIBOX_CANONICAL_PROJECT="$(cd "$AIBOX_LEGACY_PROJECT" && pwd -P)"
export AIBOX_PROJECT_HASH="$(printf '%s' "$AIBOX_CANONICAL_PROJECT" \
  | shasum -a 256 | cut -c1-6)"
printf 'project=%s\nhash=%s\n' "$AIBOX_CANONICAL_PROJECT" "$AIBOX_PROJECT_HASH"
```

Because the source contains live credentials and the copy targets a populated
home, generate and review the exact `docker run` command from the verified
inventory instead of pasting an unverified one-liner from this document.

After copying:

```sh
"$AIBOX_BIN" --dir "$AIBOX_LEGACY_PROJECT" up
"$AIBOX_BIN" --dir "$AIBOX_LEGACY_PROJECT" run claude --resume
```

Pass when the expected v2 session appears and resumes under the same canonical
project path, the source volume remains read-only and its files remain
unchanged, and the recorded cleanup commands have not been executed. Record
collisions or missing sessions as failures; do not delete the source after a
partial result.

Select a known pre-copy session identifier and confirm earlier turns, not just
an account login or a newly created conversation. Compare private source
inventories/checksums before and after the copy while consumers remain stopped;
mounting the helper read-only alone does not prove another writer was absent.
Do not publish credential contents or sensitive file lists as evidence.

Record the final state of all paused v2 consumers and restore unrelated ones
only after the source comparison is complete. Keep both the legacy destination
and old resources out of E4 cleanup. Removing either is a separate decision,
including after a successful result.

<a id="d3"></a>

### D3. Optional endurance and substitution tests

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

**Phase D checkpoint:** Record D1/D2 evidence or blockers and any optional observations. Keep the legacy source and destination intact for a separate retention decision.

<a id="phase-e"></a>

## Phase E: Record decisions and close validation

**Purpose:** convert observations into accurate product claims and a clean handoff.
**Needs:** results from the earlier phases, including unfinished/blocked checks.
Documentation and the scorecard may be drafted while external checks are blocked;
final acceptance must still reflect those blockers.

<a id="e1"></a>

### E1. Product-decision scorecard

Complete this after recording the available tests; cite their step IDs. Concrete observations matter more than a simple
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

<a id="e2"></a>

### E2. Documentation and release preparation

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
  product decisions from E1.
- Re-run A2 and `npm pack --dry-run`. If implementation changes were made,
  rerun every affected manual step before carrying its PASS forward.
- Confirm the packed archive contains only intended files and that no secret,
  test evidence, backup, session URL, or credential file is tracked.

Before calling the prototype done, also resolve the size checkpoint in
`PROTOTYPE.md` section 9.1. The post-Milestone-3 `bin/aibox` is approximately
1,375 lines, well above the document's “over 800 lines means stop and
reconsider” guide. This is not automatically a functional failure, but it is a
specification mismatch that needs an explicit decision or a focused
simplification pass before release.

This step prepares the release path; it does not publish a package, push a tag,
or create a release. Keep unavailable-platform or integration results visible
and constrain public claims to what was actually demonstrated.

<a id="e3"></a>

### E3. Final acceptance table

Use one row per step, with substep results linked from the evidence column.
A step is PASS only when its required subchecks pass; an optional subcheck such
as C2.2 does not block its parent. Record macOS and Linux results separately.

| ID | Required result | Status | Evidence or blocker |
|---|---|---|---|
| [A1](#a1) | Disposable projects, versions, resource identity, and evidence location are recorded | NOT RUN | |
| [A2](#a2) | Static checks and smoke suite pass; size checkpoint has a recorded disposition | NOT RUN | |
| [A3](#a3) | Recorded derivative provides both agents outside the private home | NOT RUN | |
| [B1](#b1) | Codex authenticates, performs only the requested edit, and resumes the exact session | NOT RUN | |
| [B2](#b2) | Claude authenticates, performs only the requested edit, and resumes the exact session | NOT RUN | |
| [B3](#b3) | Stop/start retains the container; replacement changes its ID while home/auth/sessions survive | NOT RUN | |
| [B4](#b4) | Checked export, disposable purge, import, and exact-session resume succeed | NOT RUN | |
| [B5](#b5) | Second-project home/transcript separation and repeated-login friction are demonstrated | NOT RUN | |
| [C1](#c1) | tmux survives terminal disconnection and active replacement refuses without disruption | NOT RUN | |
| [C2](#c2) | SSH reaches the same container and tmux survives SSH disconnection | NOT RUN | |
| [C3](#c3) | Real app/HMR works locally and over SSH; direct LAN access fails; forwarder survives replacement | NOT RUN | |
| [C4](#c4) | Claude Remote reaches the sandbox from another device and reconnects | NOT RUN | |
| [C5](#c5) | Docker restart behavior, retained forward, home data, and sleep/availability limits are recorded | NOT RUN | |
| [D1](#d1) | Native Linux acceptance passes and actual host file ownership/usability is recorded | NOT RUN | |
| [D2](#d2) | Known v2 session resumes at its original path, source data is unchanged, old resources are retained | NOT RUN | |
| [E1](#e1) | Product-decision scorecard is complete with step-specific evidence | NOT RUN | |
| [E2](#e2) | README, historical docs, contribution guide, metadata, and release path match demonstrated behavior | NOT RUN | |
| [E4](#e4) | Disposable resources and global customization are cleaned up or deliberately retained and recorded | NOT RUN | |

Record optional C2.2, D3, and the host-reboot extension of C5 separately; do not
silently promote them into required gates or claim them as tested.

Milestone 4 is complete only when every required row is PASS, or an explicitly
accepted limitation is documented accurately in the README and `PROTOTYPE.md`
with its impact on the supported scope. NOT RUN and external BLOCKED results
remain incomplete. An observed safety failure cannot be relabeled as an
expected limitation to close the milestone.

<a id="e4"></a>

### E4. Cleanup after recording results

Cleanup applies only to the disposable projects and schema-3 resources created
for this playbook. Re-export the A1/B5 paths and confirm they still point to
the disposable A/B projects. Skip B commands if B was never created. Inspect
resource labels before removing anything; never substitute the D2 legacy path
or destination into these commands:

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

Close any remaining host SSH tunnels and test terminals. Record intentionally
retained resources, backups, and their exact names. Remove credential-bearing
validation archives only after recovery and migration evidence is accepted.
Keep the reviewed evidence outside the disposable projects. Review `git status`
in the AI Box repo before recording E4; no acceptance fixture, credential,
archive, or session URL belongs in its commits.

**Phase E checkpoint:** Update the progress bookmark and E3 after cleanup. Report what passed, what remains blocked, and which limitations were explicitly accepted.
