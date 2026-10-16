#!/usr/bin/env bash
# Upgrade this source checkout and its already-running systemd user service.
set -euo pipefail

# The whole script is one compound command, so Bash parses all of it before
# running anything. Switching the checkout may replace this file mid-run.
{
SERVICE=hermes-webui.service
PHASE=preflight
DRY_RUN=0
SWITCH=0
ROLLBACK=0
REPO_ARG=
# Daily integration: upstream/master + the tools branch + the topics listed in
# its recipe, rebuilt from scratch in a temporary worktree.
DAILY=daily
DAILY_PREV=daily-prev
TOOLS=gz/tools
RECIPE=daily.topics
BASE_REMOTE=upstream
BASE_BRANCH=master
BASE="$BASE_REMOTE/$BASE_BRANCH"
BUILD_DIR=
fail() { printf '[upgrade] %s\n' "$*" >&2; exit 1; }
trap 'printf "[upgrade] Failed during %s; no automatic rollback. Check git status and systemctl --user status %s.\n" "$PHASE" "$SERVICE" >&2' ERR

usage() {
  printf '%s\n' \
    'Usage: upgrade.sh [--dry-run] [--switch-to-daily | --rollback] [--repo PATH] | --help' \
    'Updates the checkout, installs requirements in the active service venv' \
    '(or verifies them without installation in a Hermes-managed runtime), then restarts' \
    'hermes-webui.service and checks local /health. Run without sudo.' \
    '' \
    "On the $DAILY branch, rebuilds it from $BASE + $TOOLS + the topic branches listed" \
    "in $TOOLS:$RECIPE, in a temporary worktree, and switches the checkout only when" \
    'the build succeeded. An unchanged build does not restart the service. On any other' \
    "branch, follows its Git upstream with git pull --ff-only (refused on a topic branch)." \
    '' \
    "--switch-to-daily  build $DAILY and switch the checkout to it from any branch" \
    "--rollback         switch $DAILY back to $DAILY_PREV (the build before the last switch)" \
    '--repo PATH        upgrade the checkout at PATH instead of the script directory' \
    '--dry-run          check the runtime and print the plan; a daily trial build uses' \
    '                   current refs without fetching and is discarded'
}

while (($#)); do
  case "$1" in
    --help) usage; exit 0 ;;
    --dry-run) DRY_RUN=1 ;;
    --switch-to-daily) SWITCH=1 ;;
    --rollback) ROLLBACK=1 ;;
    --repo)
      [[ $# -ge 2 && -n "$2" ]] || fail '--repo needs a path.'
      REPO_ARG="$2"
      shift
      ;;
    *) fail 'Unknown argument. Use --help.' ;;
  esac
  shift
done
if [[ "$SWITCH" == 1 && "$ROLLBACK" == 1 ]]; then
  fail '--switch-to-daily and --rollback cannot be combined.'
fi
if [[ -n "$REPO_ARG" ]]; then
  REPO_ROOT="$(cd "$REPO_ARG" && pwd -P)" || fail "Cannot open repository: $REPO_ARG"
else
  REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
fi
[[ $EUID != 0 ]] || fail 'Run as the service user, without sudo.'
for command in git systemctl python3 flock; do
  command -v "$command" >/dev/null || fail "Missing command: $command"
done
command -v curl >/dev/null || command -v wget >/dev/null || fail 'curl or wget is required.'
cd "$REPO_ROOT"
if [[ -n "$REPO_ARG" ]]; then
  [[ "$(git rev-parse --show-toplevel 2>/dev/null)" == "$REPO_ROOT" ]] || fail 'The --repo path must be a checkout root.'
else
  [[ "$(git rev-parse --show-toplevel)" == "$REPO_ROOT" ]] || fail 'The script must be in the checkout root.'
fi
[[ -z "$(git status --porcelain --untracked-files=no)" ]] || fail 'Tracked local changes detected; commit or stash them first.'
exec 9>"$(git rev-parse --git-path hermes-webui-upgrade.lock)"
flock -n 9 || fail 'Another upgrade is running.'

BRANCH="$(git symbolic-ref --quiet --short HEAD || true)"
TOPICS=()
RAW_TOPICS=()
RECIPE_ERROR=
# Read the recipe from the tools branch itself, never from the working tree:
# a PR branch checked out from master has no copy of it. Sets RAW_TOPICS, or
# RECIPE_ERROR without failing, so pull mode can ignore a broken recipe.
parse_recipe() {
  local text line topic extra
  RAW_TOPICS=()
  RECIPE_ERROR=
  if ! git rev-parse --verify --quiet "refs/heads/$TOOLS^{commit}" >/dev/null; then
    RECIPE_ERROR="Missing branch $TOOLS."
    return 0
  fi
  if ! text="$(git show "refs/heads/$TOOLS:$RECIPE" 2>/dev/null)"; then
    RECIPE_ERROR="Cannot read $RECIPE from $TOOLS."
    return 0
  fi
  while IFS= read -r line; do
    line="${line%$'\r'}"
    # A comment starts the line or follows whitespace; '#' is legal in a branch.
    [[ "$line" != \#* ]] || continue
    line="${line%%[[:space:]]#*}"
    read -r topic extra <<< "$line" || true
    [[ -n "$topic" ]] || continue
    if [[ -n "$extra" ]]; then
      RECIPE_ERROR="$RECIPE: one branch per line: $line"
      return 0
    fi
    RAW_TOPICS+=("$topic")
  done <<< "$text"
}

read_topics() {
  local topic seen=" "
  parse_recipe
  [[ -z "$RECIPE_ERROR" ]] || fail "$RECIPE_ERROR"
  TOPICS=()
  for topic in "${RAW_TOPICS[@]}"; do
    git check-ref-format --branch "$topic" >/dev/null 2>&1 || fail "$RECIPE: invalid branch name: $topic"
    case "$topic" in
      "$DAILY"|"$DAILY_PREV"|"$TOOLS") fail "$RECIPE must not list $topic." ;;
    esac
    [[ "$seen" != *" $topic "* ]] || fail "$RECIPE lists $topic twice."
    seen+="$topic "
    git rev-parse --verify --quiet "refs/heads/$topic^{commit}" >/dev/null || fail "Topic branch $topic from $RECIPE does not exist locally."
    TOPICS+=("$topic")
  done
}

if [[ "$ROLLBACK" == 1 ]]; then
  GIT_MODE=rollback
  [[ "$BRANCH" == "$DAILY" ]] || fail "--rollback works only with $DAILY checked out."
  git rev-parse --verify --quiet "refs/heads/$DAILY_PREV^{commit}" >/dev/null || fail "No $DAILY_PREV to roll back to."
elif [[ "$BRANCH" == "$DAILY" || "$SWITCH" == 1 ]]; then
  GIT_MODE=daily
  read_topics
else
  GIT_MODE=pull
  if [[ -n "$BRANCH" ]]; then
    # Only membership matters here; a stale recipe must not block a pull.
    parse_recipe
    for topic in "${RAW_TOPICS[@]}"; do
      [[ "$topic" != "$BRANCH" ]] || fail "$BRANCH is a topic branch from $RECIPE; use --switch-to-daily to build $DAILY and switch to it."
    done
  fi
  git rev-parse --abbrev-ref '@{upstream}' >/dev/null || fail 'No Git upstream configured.'
fi
systemctl --user is-active --quiet "$SERVICE" || fail 'The user service must already be running so its runtime can be identified safely.'
PID="$(systemctl --user show "$SERVICE" --property=MainPID --value)"
[[ "$PID" =~ ^[1-9][0-9]*$ ]] || fail 'Cannot identify service PID.'

# Read runtime metadata, not .env/auth/config files. Output only non-secret fields.
identify_runtime() {
python3 - "$PID" "$REPO_ROOT" <<'PY'
import ast
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

proc = Path('/proc') / sys.argv[1]
repo = Path(sys.argv[2])
try:
    if proc.stat().st_uid != os.getuid():
        raise ValueError('service process belongs to another user')
    cmdline = (proc / 'cmdline').read_bytes()
    argv = [os.fsdecode(x) for x in cmdline.split(b'\0') if x]
    index = 1
    while index < len(argv) and argv[index] in {'-u', '-B', '-I', '-E', '-s'}:
        index += 1
    target = None
    agent_root = None
    if index < len(argv) and argv[index] == '-c' and len(argv) == index + 2:
        # Accept the exact stdlib-only re-entry emitted by Hermes, not an
        # arbitrary command merely containing the expected server path.
        tree = ast.parse(argv[index + 1])
        if len(tree.body) == 4:
            root = ast.literal_eval(tree.body[1].value.args[1])
            args = ast.literal_eval(tree.body[2].value)
            if isinstance(root, str) and isinstance(args, list) and args and all(isinstance(x, str) for x in args):
                expected = ast.parse(
                    f'import sys, runpy; sys.path.insert(0, {root!r}); '
                    f'sys.argv = {args!r}; runpy.run_path({args[0]!r}, run_name="__main__")'
                )
                if ast.dump(tree) == ast.dump(expected):
                    target = args[0]
                    agent_root = Path(root)
    elif index < len(argv) and not argv[index].startswith('-'):
        target = argv[index]
    if not target or not Path(target).is_absolute() or Path(target).resolve() != repo / 'server.py':
        raise ValueError('service is not running server.py from this checkout')
    python = argv[0]
    if not Path(python).is_absolute() or not os.access(python, os.X_OK):
        raise ValueError('runtime interpreter is not an executable absolute path')
    if not Path(python).samefile(proc / 'exe'):
        raise ValueError('runtime interpreter no longer matches the live process')
    allowed = {b'HERMES_WEBUI_HOST', b'HERMES_WEBUI_PORT',
               b'HERMES_WEBUI_TLS_CERT', b'HERMES_WEBUI_TLS_KEY',
               b'HOME', b'HERMES_HOME', b'HERMES_RUNTIME_DIR'}
    values = {}
    for entry in (proc / 'environ').read_bytes().split(b'\0'):
        name, sep, value = entry.partition(b'=')
        if sep and name in allowed:
            values[os.fsdecode(name)] = os.fsdecode(value)
    host = values.get('HERMES_WEBUI_HOST', '127.0.0.1')
    host = {'0.0.0.0': '127.0.0.1', '::': '[::1]', '::1': '[::1]'}.get(host, host)
    if host not in {'127.0.0.1', '[::1]', 'localhost'}:
        raise ValueError('health checks are restricted to loopback hosts')
    port = values.get('HERMES_WEBUI_PORT', '8787')
    if not port.isascii() or not port.isdecimal() or not 1 <= int(port) <= 65535:
        raise ValueError('invalid service port')
    tls = bool(values.get('HERMES_WEBUI_TLS_CERT') and values.get('HERMES_WEBUI_TLS_KEY'))
    # The isolated metadata probe never imports run_agent/hermes_bootstrap:
    # those imports may perform startup repair or re-exec into another runtime.
    probe = '''import json, sys
from pathlib import Path
mode, selected = 'venv', ''
if sys.prefix == sys.base_prefix:
    root = Path(sys.argv[1])
    if not root.is_absolute() or not (root / 'run_agent.py').is_file():
        raise ValueError('non-venv interpreter has no verified Hermes launcher root')
    sys.path.insert(0, str(root))
    from pm.environments import committed_venv, site_packages, venv_python
    environment = committed_venv(root)
    if environment is None or not venv_python(environment).samefile(sys.executable):
        raise ValueError('no committed dependency environment for this interpreter')
    selected = str(site_packages(environment).resolve())
    if not Path(selected).is_dir():
        raise ValueError('committed site-packages is missing')
    mode = 'managed'
print(json.dumps([mode, selected]))
'''
    probe_env = {key: value for key, value in values.items()
                 if key in {'HOME', 'HERMES_HOME', 'HERMES_RUNTIME_DIR'}}
    checked = subprocess.run([python, '-I', '-c', probe, str(agent_root or '')],
                             env=probe_env, capture_output=True, text=True, timeout=15)
    if checked.returncode:
        raise ValueError('cannot verify a venv or committed Hermes dependency environment; refusing system-Python installation')
    mode, selected = json.loads(checked.stdout)
    # Include process start time and launch metadata in the later revalidation.
    start_time = (proc / 'stat').read_text().rsplit(')', 1)[1].split()[19]
    identity = hashlib.sha256(cmdline + start_time.encode() + json.dumps(values, sort_keys=True).encode()).hexdigest()
    fields = [python, host, port, '1' if tls else '0', mode, selected, identity]
    if any('\n' in item or '\r' in item for item in fields):
        raise ValueError('invalid runtime metadata')
    print('\n'.join(fields))
except (OSError, ValueError, SyntaxError, AttributeError, IndexError, TypeError, subprocess.TimeoutExpired) as exc:
    sys.exit(f'[upgrade] Cannot identify runtime: {exc}')
PY
}
RUNTIME="$(identify_runtime)"
mapfile -t FIELDS <<< "$RUNTIME"
PYTHON="${FIELDS[0]}"
HOST="${FIELDS[1]}"
PORT="${FIELDS[2]}"
MODE="${FIELDS[4]}"
SITE="${FIELDS[5]}"

check_managed_dependencies() {
  "$PYTHON" -I - "$SITE" "$REPO_ROOT/requirements.txt" <<'PY'
import importlib.metadata
from pathlib import Path
import sys

# Metadata and packaging come only from the committed generation, not the
# caller's activated venv, PYTHONPATH or an old in-checkout Agent venv.
sys.path.insert(0, sys.argv[1])
try:
    from packaging.requirements import Requirement
    from packaging.utils import canonicalize_name
    versions = {canonicalize_name(dist.metadata['Name']): dist.version
                for dist in importlib.metadata.distributions(path=[sys.argv[1]])}
    missing = []
    for line in Path(sys.argv[2]).read_text().splitlines():
        line = line.split(' #', 1)[0].strip()
        if not line or line.startswith('#'):
            continue
        requirement = Requirement(line)
        if requirement.url or requirement.extras:
            raise ValueError('URL and extra requirements need an independently configured WebUI environment')
        if requirement.marker and not requirement.marker.evaluate():
            continue
        name = canonicalize_name(requirement.name)
        version = versions.get(name)
        # WebUI's api.yaml_compat and bootstrap explicitly support ruamel.yaml
        # when PyYAML is unavailable in the managed Hermes dependency graph.
        if name == 'pyyaml' and version is None and 'ruamel-yaml' in versions:
            continue
        if version is None or not requirement.specifier.contains(version):
            missing.append(str(requirement))
    if missing:
        raise ValueError('unsatisfied requirements: ' + ', '.join(missing))
except (OSError, ValueError, ImportError, KeyError) as exc:
    sys.exit(f'[upgrade] Managed dependency check failed: {exc}. '
             'Configure a dedicated WebUI runtime or update Hermes separately; '
             'this script will not modify a PM-managed generation.')
print('[upgrade] Managed dependencies: satisfied (no installation).')
PY
}

revalidate_runtime() {
  [[ "$(systemctl --user show "$SERVICE" --property=MainPID --value)" == "$PID" ]] || fail 'Service PID changed; rerun to identify its current runtime.'
  [[ "$(identify_runtime)" == "$RUNTIME" ]] || fail 'Service runtime or managed dependency selection changed; rerun.'
}

if [[ "$MODE" == managed ]]; then
  check_managed_dependencies
else
  "$PYTHON" -I -m pip --version >/dev/null || fail 'The service venv has no pip; no changes made.'
fi
cleanup_build() {
  [[ -n "$BUILD_DIR" ]] || return 0
  git -C "$REPO_ROOT" worktree remove --force "$BUILD_DIR/tree" >/dev/null 2>&1 || true
  rm -rf "$BUILD_DIR"
  git -C "$REPO_ROOT" worktree prune >/dev/null 2>&1 || true
  BUILD_DIR=
}
trap cleanup_build EXIT

# Build the daily commit in a temporary worktree; the checkout is untouched.
# Sets NEW_DAILY. A conflict that rerere cannot resolve aborts the build.
build_daily() {
  local tree topic unmerged
  git rev-parse --verify --quiet "refs/remotes/$BASE^{commit}" >/dev/null || fail "Missing $BASE; fetch $BASE_REMOTE first."
  # Inside the git dir, on disk: /tmp may be a RAM-backed tmpfs.
  BUILD_DIR="$(mktemp -d "$(git rev-parse --path-format=absolute --git-common-dir)/hermes-daily.XXXXXX")"
  tree="$BUILD_DIR/tree"
  # No background auto-maintenance: it writes into the worktree's admin dir
  # and races the removal in cleanup_build.
  if ! git -c gc.auto=0 -c maintenance.auto=false \
      worktree add --quiet --detach "$tree" "refs/remotes/$BASE" >"$BUILD_DIR/merge.log" 2>&1; then
    cat "$BUILD_DIR/merge.log" >&2
    fail 'Cannot create a temporary worktree for the daily build.'
  fi
  for topic in "$TOOLS" "${TOPICS[@]}"; do
    if git merge-base --is-ancestor "refs/heads/$topic" "refs/remotes/$BASE"; then
      if [[ "$topic" != "$TOOLS" ]]; then
        printf '[upgrade] Note: %s is already in %s; remove it from %s.\n' "$topic" "$BASE" "$RECIPE"
      fi
      continue
    fi
    if ! git -C "$tree" -c gc.auto=0 -c maintenance.auto=false -c rerere.enabled=true -c rerere.autoUpdate=true \
        merge --quiet --no-ff --no-edit -m "daily: merge $topic" "refs/heads/$topic" >"$BUILD_DIR/merge.log" 2>&1; then
      if ! git -C "$tree" rev-parse --verify --quiet MERGE_HEAD >/dev/null; then
        cat "$BUILD_DIR/merge.log" >&2
        fail "Merging $topic failed; $DAILY and the checkout were not changed."
      fi
      unmerged="$(git -C "$tree" diff --name-only --diff-filter=U)"
      if [[ -n "$unmerged" ]]; then
        printf '[upgrade] Conflict merging %s:\n%s\n' "$topic" "$unmerged" >&2
        fail "Resolve it once with rerere enabled, then rerun; $DAILY and the checkout were not changed."
      fi
      git -C "$tree" -c gc.auto=0 -c maintenance.auto=false commit --quiet --no-edit >/dev/null
      printf '[upgrade] Reused a recorded conflict resolution for %s.\n' "$topic"
    fi
  done
  NEW_DAILY="$(git -C "$tree" rev-parse HEAD)"
  cleanup_build
}

# Switch the checkout to $DAILY at $1. A failed checkout leaves the branch as
# it was; the replaced daily becomes $DAILY_PREV only after a successful one.
switch_daily() {
  local old
  old="$(git rev-parse --verify --quiet "refs/heads/$DAILY^{commit}" || true)"
  git switch --quiet --no-guess -C "$DAILY" "$1" || fail "Cannot switch the checkout to $DAILY; it was not changed. Move the files Git names above and rerun."
  if [[ -n "$old" && "$old" != "$1" ]]; then
    git branch --force "$DAILY_PREV" "$old"
  fi
}

# The last daily that passed the health check, and the inputs it was built
# from. "Up to date" needs both: a run that switched but then failed to install,
# restart or pass /health must be retried, not reported as current.
STATE_FILE="$(git rev-parse --git-path hermes-webui-daily.state)"
STATE_INPUTS=
STATE_HEALTHY=
if [[ -f "$STATE_FILE" ]]; then
  while IFS='=' read -r key value; do
    case "$key" in
      inputs) STATE_INPUTS="$value" ;;
      healthy) STATE_HEALTHY="$value" ;;
    esac
  done < "$STATE_FILE"
fi
write_state() {
  printf 'inputs=%s\nhealthy=%s\n' "$1" "$2" > "$STATE_FILE.tmp"
  mv -f "$STATE_FILE.tmp" "$STATE_FILE"
}
daily_inputs() {
  local topic
  {
    printf '%s %s\n' "$BASE" "$(git rev-parse "refs/remotes/$BASE")"
    for topic in "$TOOLS" "${TOPICS[@]}"; do
      printf '%s %s\n' "$topic" "$(git rev-parse "refs/heads/$topic")"
    done
  } | git hash-object --stdin
}

UNCHANGED=0
NEW_DAILY=
INPUTS=
if [[ "$GIT_MODE" == daily ]]; then
  PHASE='daily build'
  if [[ "$DRY_RUN" == 0 ]]; then
    git fetch --quiet --no-tags "$BASE_REMOTE" "$BASE_BRANCH"
  fi
  INPUTS="$(daily_inputs)"
  CURRENT="$(git rev-parse --verify --quiet "refs/heads/$DAILY^{commit}" || true)"
  if [[ "$BRANCH" == "$DAILY" && -n "$CURRENT" && "$STATE_HEALTHY" == "$CURRENT" && "$STATE_INPUTS" == "$INPUTS" ]]; then
    # Same inputs as the last healthy build: skip the worktree entirely.
    NEW_DAILY="$CURRENT"
    UNCHANGED=1
  else
    build_daily
    if [[ -n "$CURRENT" && "$(git rev-parse "$NEW_DAILY^{tree}")" == "$(git rev-parse "$CURRENT^{tree}")" ]]; then
      # Same content: keep the existing commit instead of a new identical merge.
      NEW_DAILY="$CURRENT"
      if [[ "$BRANCH" == "$DAILY" && "$STATE_HEALTHY" == "$CURRENT" ]]; then
        UNCHANGED=1
        [[ "$DRY_RUN" == 1 ]] || write_state "$INPUTS" "$CURRENT"
      fi
    fi
  fi
  printf '[upgrade] Daily: %s + %s' "$BASE" "$TOOLS"
  for topic in "${TOPICS[@]}"; do printf ' + %s' "$topic"; done
  printf '\n'
elif [[ "$GIT_MODE" == rollback ]]; then
  NEW_DAILY="$(git rev-parse "refs/heads/$DAILY_PREV")"
fi

printf '[upgrade] Repository: %s\n[upgrade] Runtime: %s\n' "$REPO_ROOT" "$PYTHON"
printf '[upgrade] Dependency mode: %s\n' "$MODE"
if [[ "$UNCHANGED" == 1 && "$DRY_RUN" == 0 ]]; then
  printf '[upgrade] %s is up to date (%s); nothing to switch or restart.\n' "$DAILY" "$(git rev-parse --short HEAD)"
  exit 0
fi
if [[ "$DRY_RUN" == 1 ]]; then
  case "$GIT_MODE" in
    pull) printf '[upgrade] Would run: git pull --ff-only\n' ;;
    daily)
      if [[ "$UNCHANGED" == 1 ]]; then
        printf '[upgrade] Current refs (not fetched) give the running %s; a real run fetches first and restarts only if that changes it.\n' "$DAILY"
      else
        printf '[upgrade] Trial build from current refs succeeded (not fetched).\n'
      fi
      printf '[upgrade] Would run: git fetch --no-tags %s %s, rebuild, and switch the checkout to %s\n' "$BASE_REMOTE" "$BASE_BRANCH" "$DAILY"
      ;;
    rollback) printf '[upgrade] Would switch %s back to %s (%s)\n' "$DAILY" "$DAILY_PREV" "$(git rev-parse --short "$NEW_DAILY")" ;;
  esac
  if [[ "$MODE" == managed ]]; then
    printf '[upgrade] Would recheck pulled requirements in the committed Hermes environment (no pip install).\n'
  else
    printf '[upgrade] Would run: %q -I -m pip install --disable-pip-version-check -r %q\n' "$PYTHON" "$REPO_ROOT/requirements.txt"
  fi
  printf '[upgrade] Would run: systemctl --user restart %s\n' "$SERVICE"
  printf '[upgrade] Would verify local /health at %s:%s\n' "$HOST" "$PORT"
  exit 0
fi

if [[ "$GIT_MODE" == pull ]]; then
  PHASE='Git pull'
  revalidate_runtime
  git pull --ff-only
else
  PHASE='checkout switch'
  revalidate_runtime
  switch_daily "$NEW_DAILY"
fi
PHASE='dependency installation'
revalidate_runtime
if [[ "$MODE" == managed ]]; then
  check_managed_dependencies
else
  "$PYTHON" -I -m pip install --disable-pip-version-check -r "$REPO_ROOT/requirements.txt"
fi
PHASE='service restart'
revalidate_runtime
systemctl --user restart "$SERVICE"
PHASE='health verification'
# Reuse the launchers TLS-aware probe, always bypassing local proxy settings.
source "$REPO_ROOT/scripts/lib/health_probe.sh"
unset HERMES_WEBUI_TLS_CERT HERMES_WEBUI_TLS_KEY HERMES_WEBUI_TLS_INSECURE_PROBE
if [[ "${FIELDS[3]}" == 1 ]]; then
  export HERMES_WEBUI_TLS_CERT=runtime-configured HERMES_WEBUI_TLS_KEY=runtime-configured
fi
for ((attempt=0; attempt<30; attempt++)); do
  if systemctl --user is-active --quiet "$SERVICE" && \
      BODY="$(hermes_webui_probe_health "$HOST" "$PORT" /health 2 direct)" && \
      printf '%s' "$BODY" | python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin).get("status") == "ok" else 1)' 2>/dev/null; then
    if [[ "$GIT_MODE" == daily ]]; then
      write_state "$INPUTS" "$(git rev-parse HEAD)"
    elif [[ "$GIT_MODE" == rollback ]]; then
      # No recipe inputs for a rollback: the next run rebuilds and moves forward.
      write_state '' "$(git rev-parse HEAD)"
    fi
    printf '[upgrade] Health: ok\n[upgrade] Commit: %s\n' "$(git rev-parse --short HEAD)"
    exit 0
  fi
  sleep 1
done
fail "Health check failed. Inspect: journalctl --user -u $SERVICE -n 80"
exit
}
