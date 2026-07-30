#!/usr/bin/env bash
# migrate-to-v2.sh — one-time migration of aibox v1 data into the v2
# aibox-home volume. Standalone: not part of the aibox CLI, run it once.
#
# Usage:
#   ./migrate-to-v2.sh [--map OLD_PATH=NEW_PATH]... [old-backup-dir ...]
#
# What it does, in order:
#   1. Creates the aibox-home volume if missing.
#   2. Merges every `aibox-auth-*` Docker volume (v1 kept one per image
#      string) into aibox-home. Sources are mounted READ-ONLY and are never
#      modified or deleted.
#   3. Merges any old backup folders passed as arguments. Two layouts are
#      accepted: a folder that *is* a Claude config dir (contains
#      .claude.json / projects/), or a folder containing a `.claude/` dir
#      (with .claude.json beside or inside it).
#   4. Session/state files merge file-by-file, no-clobber (each session is
#      its own .jsonl keyed by UUID, so a plain union is correct).
#      `.claude.json` is special-cased: the newest copy is the base, and the
#      `projects` map is merged across all copies with newest-wins per key.
#   5. `--map OLD=NEW` rekeys sessions recorded under a container-side path
#      (v1 --copy/--worktree used /workspace/...) to a real host path, e.g.
#      --map /workspace/myapp=/Users/me/code/myapp. Renames both the
#      projects/<escaped-path> directories and the .claude.json keys.
#      (Path escaping is lossy — any non-alphanumeric becomes '-' — so the
#      prefix match can theoretically over-match; only use --map for paths
#      you recognize.)
#
# Idempotent: run it twice and the second run copies nothing new.
# It ends by PRINTING the cleanup commands for old volumes/containers —
# it never runs them. Verify sessions in v2 first, then clean up manually.

set -euo pipefail

VOLUME="aibox-home"
HELPER_IMAGE="alpine"

info() { echo "· $*"; }
ok()   { echo "✓ $*"; }
die()  { echo "✗ $*" >&2; exit 1; }

command -v docker >/dev/null 2>&1 || die "docker not found"
docker info >/dev/null 2>&1 || die "Docker daemon not running"
command -v python3 >/dev/null 2>&1 || die "python3 not found (needed for the .claude.json merge)"

# ── Args ─────────────────────────────────────────────────────────
MAPS=()          # OLD=NEW pairs
BACKUP_DIRS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --map)
      [[ "${2:-}" == *=* ]] || die "--map needs OLD_PATH=NEW_PATH"
      MAPS+=("$2"); shift 2 ;;
    -h|--help)
      sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)
      [[ -d "$1" ]] || die "Not a directory: $1"
      BACKUP_DIRS+=("$(cd "$1" && pwd)"); shift ;;
  esac
done

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

docker volume create "$VOLUME" >/dev/null 2>&1 || true
docker run --rm -v "${VOLUME}:/dst" "$HELPER_IMAGE" mkdir -p /dst/.claude

# ── Helpers ──────────────────────────────────────────────────────
escape() { printf '%s' "$1" | sed 's/[^a-zA-Z0-9]/-/g'; }

# --map pairs in escaped form ("old=new;old2=new2") so the copy step can
# land files directly at their mapped path (keeps re-runs copy-free).
ESC_MAPS=""
for m in ${MAPS[@]+"${MAPS[@]}"}; do
  ESC_MAPS="${ESC_MAPS}$(escape "${m%%=*}")=$(escape "${m#*=}");"
done

# Copy everything except .claude.json from /src into /dst/.claude,
# file-by-file, never overwriting; paths under projects/ are rewritten
# through ESC_MAPS. Prints the number of files copied.
COPY_SCRIPT='map_path() {
  case "$1" in projects/*) ;; *) printf "%s" "$1"; return;; esac
  rest="${1#projects/}"
  oldifs="$IFS"; IFS=";"
  for pair in $ESC_MAPS; do
    old="${pair%%=*}"; new="${pair#*=}"
    case "$rest" in "$old"*) rest="${new}${rest#"$old"}"; break;; esac
  done
  IFS="$oldifs"
  printf "projects/%s" "$rest"
}
cd /src && find . -type f ! -path "./.claude.json" | while IFS= read -r f; do
  s="${f#./}"
  d="$(map_path "$s")"
  if [ ! -e "/dst/.claude/$d" ]; then
    mkdir -p "/dst/.claude/$(dirname "$d")"
    cp -p "$s" "/dst/.claude/$d" && echo x
  fi
done | wc -l'

# Save a source's .claude.json (if any) into staging as <mtime>.<n>.json
JSON_N=0
stage_json() {  # $1 = mtime, stdin = content
  local content
  content="$(cat)"
  [[ -z "$content" || -z "$1" || "$1" == "0" ]] && return 0
  JSON_N=$((JSON_N + 1))
  printf '%s' "$content" > "${STAGING}/${1}.${JSON_N}.json"
}

merge_from_volume() {  # $1 = volume name
  local vol="$1" copied meta
  copied="$(docker run --rm -e ESC_MAPS="$ESC_MAPS" -v "${vol}:/src:ro" -v "${VOLUME}:/dst" "$HELPER_IMAGE" sh -c "$COPY_SCRIPT")"
  meta="$(docker run --rm -v "${vol}:/src:ro" "$HELPER_IMAGE" sh -c \
    'stat -c %Y /src/.claude.json 2>/dev/null || echo 0')"
  docker run --rm -v "${vol}:/src:ro" "$HELPER_IMAGE" sh -c \
    'cat /src/.claude.json 2>/dev/null || true' | stage_json "$meta"
  ok "volume ${vol}: ${copied// /} new file(s)"
}

host_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0; }

merge_from_dir() {  # $1 = backup dir
  local dir="$1" src json=""
  if [[ -d "${dir}/.claude" ]]; then
    src="${dir}/.claude"
    [[ -f "${dir}/.claude.json" ]] && json="${dir}/.claude.json"
    [[ -z "$json" && -f "${dir}/.claude/.claude.json" ]] && json="${dir}/.claude/.claude.json"
  elif [[ -d "${dir}/projects" || -f "${dir}/.claude.json" ]]; then
    src="$dir"
    [[ -f "${dir}/.claude.json" ]] && json="${dir}/.claude.json"
  else
    info "skipping ${dir}: no Claude data recognized (expected .claude/ or projects/)"
    return 0
  fi
  local copied
  copied="$(docker run --rm -e ESC_MAPS="$ESC_MAPS" -v "${src}:/src:ro" -v "${VOLUME}:/dst" "$HELPER_IMAGE" sh -c "$COPY_SCRIPT")"
  [[ -n "$json" ]] && stage_json "$(host_mtime "$json")" < "$json"
  ok "backup ${dir}: ${copied// /} new file(s)"
}

# ── 1. Live v1 volumes ───────────────────────────────────────────
AUTH_VOLS="$(docker volume ls --format '{{.Name}}' | grep '^aibox-auth-' || true)"
if [[ -n "$AUTH_VOLS" ]]; then
  while IFS= read -r vol; do
    merge_from_volume "$vol"
  done <<< "$AUTH_VOLS"
else
  info "no aibox-auth-* volumes found"
fi

# ── 2. Old backup folders ────────────────────────────────────────
for dir in ${BACKUP_DIRS[@]+"${BACKUP_DIRS[@]}"}; do
  merge_from_dir "$dir"
done

# ── 3. Merge .claude.json ────────────────────────────────────────
# Include the destination's current .claude.json as a source, so re-runs and
# incremental migrations stay stable.
docker run --rm -v "${VOLUME}:/src/.claude:ro" "$HELPER_IMAGE" sh -c \
  'cat /src/.claude/.claude.json 2>/dev/null || true' \
  | stage_json "$(docker run --rm -v "${VOLUME}:/v:ro" "$HELPER_IMAGE" sh -c \
      'stat -c %Y /v/.claude.json 2>/dev/null || echo 0')"

if ls "${STAGING}"/*.json >/dev/null 2>&1; then
  python3 - "$STAGING" ${MAPS[@]+"${MAPS[@]}"} <<'PY'
import json, sys, glob, os
staging = sys.argv[1]
maps = [m.split("=", 1) for m in sys.argv[2:]]
sources = []
for path in glob.glob(os.path.join(staging, "*.json")):
    mtime = int(os.path.basename(path).split(".")[0])
    try:
        with open(path) as f:
            sources.append((mtime, json.load(f)))
    except (json.JSONDecodeError, ValueError):
        print(f"· skipping unparseable {os.path.basename(path)}", file=sys.stderr)
sources.sort(key=lambda s: s[0])
if not sources:
    sys.exit(0)
base = dict(sources[-1][1])            # newest copy wins for oauth etc.
projects = {}
for _, doc in sources:                 # oldest→newest: newest wins per key
    projects.update(doc.get("projects", {}) or {})
for old, new in maps:
    for key in list(projects):
        if key == old or key.startswith(old.rstrip("/") + "/"):
            newkey = new + key[len(old.rstrip("/")):] if key != old else new
            projects.setdefault(newkey, projects.pop(key))
base["projects"] = projects
with open(os.path.join(staging, "merged.out"), "w") as f:
    json.dump(base, f, indent=2)
print(f"· merged .claude.json from {len(sources)} source(s), {len(projects)} project(s)")
PY
  if [[ -f "${STAGING}/merged.out" ]]; then
    docker run --rm -v "${STAGING}:/stage:ro" -v "${VOLUME}:/dst" "$HELPER_IMAGE" \
      sh -c 'cp /stage/merged.out /dst/.claude/.claude.json && chmod 600 /dst/.claude/.claude.json'
    ok "wrote merged .claude.json"
  fi
else
  info "no .claude.json found in any source"
fi

# ── 4. --map: rename session directories already in the volume ───
# (New copies are mapped at copy time; this handles data that landed in the
# volume before the map was applied, e.g. an earlier migration run.)
for m in ${MAPS[@]+"${MAPS[@]}"}; do
  esc_old="$(escape "${m%%=*}")"
  esc_new="$(escape "${m#*=}")"
  docker run --rm -v "${VOLUME}:/dst" -e OLD="$esc_old" -e NEW="$esc_new" "$HELPER_IMAGE" sh -c '
    for d in /dst/.claude/projects/${OLD}*; do
      [ -d "$d" ] || continue
      rest="${d#/dst/.claude/projects/$OLD}"
      tgt="/dst/.claude/projects/${NEW}${rest}"
      if [ ! -e "$tgt" ]; then
        mv "$d" "$tgt" && echo "· moved $(basename "$d") -> $(basename "$tgt")"
      else
        cd "$d" && find . -type f | while IFS= read -r f; do
          f="${f#./}"
          [ -e "$tgt/$f" ] || { mkdir -p "$tgt/$(dirname "$f")"; mv "$f" "$tgt/$f"; }
        done
        # Anything left in $d duplicates a file already at the target
        cd / && rm -rf "$d"
        echo "· merged $(basename "$d") into $(basename "$tgt")"
      fi
    done'
done

# ── 5. Normalize ownership for the v2 container user (uid 1000) ──
docker run --rm -v "${VOLUME}:/dst" "$HELPER_IMAGE" chown -R 1000:1000 /dst
ok "ownership normalized (uid 1000)"

# ── Summary ──────────────────────────────────────────────────────
TOTAL="$(docker run --rm -v "${VOLUME}:/v:ro" "$HELPER_IMAGE" sh -c 'find /v -type f | wc -l')"
SESSIONS="$(docker run --rm -v "${VOLUME}:/v:ro" "$HELPER_IMAGE" sh -c 'find /v/.claude/projects -name "*.jsonl" 2>/dev/null | wc -l')"
echo ""
ok "Done. ${VOLUME} now holds ${TOTAL// /} file(s), ${SESSIONS// /} session file(s)."
echo ""
echo "Verify with:  cd <a project> && aibox claude --resume"
echo ""
echo "Nothing was deleted. Once you've verified v2 sees your sessions, clean up"
echo "the old v1 resources manually:"
V1_CONTAINERS="$(docker ps -a --filter label=aibox.instance --format '{{.Names}}' || true)"
if [[ -n "$V1_CONTAINERS" ]]; then
  while IFS= read -r c; do echo "  docker rm -f ${c}"; done <<< "$V1_CONTAINERS"
fi
if [[ -n "$AUTH_VOLS" ]]; then
  while IFS= read -r v; do echo "  docker volume rm ${v}"; done <<< "$AUTH_VOLS"
fi
if [[ -z "$V1_CONTAINERS" && -z "$AUTH_VOLS" ]]; then
  echo "  (none found)"
fi
