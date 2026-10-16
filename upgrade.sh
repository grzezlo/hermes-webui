#!/usr/bin/env bash
# Upgrade this source checkout and its already-running systemd user service.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SERVICE=hermes-webui.service
PHASE=preflight
DRY_RUN=0
fail() { printf '[upgrade] %s\n' "$*" >&2; exit 1; }
trap 'printf "[upgrade] Failed during %s; no automatic rollback. Check git status and systemctl --user status %s.\n" "$PHASE" "$SERVICE" >&2' ERR

if [[ "${1:-}" == --help && $# == 1 ]]; then
  printf 'Usage: ./upgrade.sh [--dry-run | --help]\nUpdates the current Git upstream, installs requirements in the active service venv\n(or verifies them without installation in a Hermes-managed runtime), then restarts\nhermes-webui.service and checks local /health. Run without sudo.\n--dry-run checks the runtime and prints the plan without pulling/installing/restarting.\n'
  exit 0
fi
if [[ "${1:-}" == --dry-run && $# == 1 ]]; then
  DRY_RUN=1
elif [[ $# != 0 ]]; then
  fail 'Unknown argument. Use --help.'
fi
[[ $EUID != 0 ]] || fail 'Run as the service user, without sudo.'
for command in git systemctl python3 flock; do
  command -v "$command" >/dev/null || fail "Missing command: $command"
done
command -v curl >/dev/null || command -v wget >/dev/null || fail 'curl or wget is required.'
cd "$REPO_ROOT"
[[ "$(git rev-parse --show-toplevel)" == "$REPO_ROOT" ]] || fail 'The script must be in the checkout root.'
[[ -z "$(git status --porcelain --untracked-files=no)" ]] || fail 'Tracked local changes detected; commit or stash them first.'
git rev-parse --abbrev-ref '@{upstream}' >/dev/null || fail 'No Git upstream configured.'
exec 9>"$(git rev-parse --git-path hermes-webui-upgrade.lock)"
flock -n 9 || fail 'Another upgrade is running.'
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
printf '[upgrade] Repository: %s\n[upgrade] Runtime: %s\n' "$REPO_ROOT" "$PYTHON"
printf '[upgrade] Dependency mode: %s\n' "$MODE"
if [[ "$DRY_RUN" == 1 ]]; then
  printf '[upgrade] Would run: git pull --ff-only\n'
  if [[ "$MODE" == managed ]]; then
    printf '[upgrade] Would recheck pulled requirements in the committed Hermes environment (no pip install).\n'
  else
    printf '[upgrade] Would run: %q -I -m pip install --disable-pip-version-check -r %q\n' "$PYTHON" "$REPO_ROOT/requirements.txt"
  fi
  printf '[upgrade] Would run: systemctl --user restart %s\n' "$SERVICE"
  printf '[upgrade] Would verify local /health at %s:%s\n' "$HOST" "$PORT"
  exit 0
fi

PHASE='Git pull'
revalidate_runtime
git pull --ff-only
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
    printf '[upgrade] Health: ok\n[upgrade] Commit: %s\n' "$(git rev-parse --short HEAD)"
    exit 0
  fi
  sleep 1
done
fail "Health check failed. Inspect: journalctl --user -u $SERVICE -n 80"
