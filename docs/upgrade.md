# Updating a source checkout with a systemd user service

`upgrade.sh` automates updates for Linux source checkouts running as the current
user's `hermes-webui.service`. It requires an already-running service, Bash,
Python 3, Git, `flock`, and curl or wget. It does not support Docker, system-wide
units, stopped services, or frozen executables. Run it without sudo.

```bash
./upgrade.sh --dry-run
./upgrade.sh
```

The script resolves its own checkout root and identifies the actual service
interpreter and local health endpoint from its live process. It supports direct
`python server.py` launches with the recognized interpreter flags (`-u`, `-B`,
`-I`, `-E`, `-s`) and the exact `python -I -c` / `runpy.run_path` re-entry emitted
by Hermes' launcher. Inline code is parsed as an AST, never evaluated by the
detector; merely mentioning the correct server path is not accepted.

It refuses unknown runtime ownership, a server from another checkout, an
unverified system interpreter, missing pip in ordinary venv mode, tracked local
changes, or concurrent upgrades. It checks that the interpreter still matches
the live executable and revalidates process identity and dependency selection
before pulling, installing/checking dependencies, and restarting. It does not
load credential/config files or print the process environment.

The update follows the current branch's configured Git upstream with
`git pull --ff-only`; it does not select the WebUI Settings stable/experimental
channel. In ordinary venv mode it runs `python -I -m pip install -r requirements.txt`
using the service interpreter, restarts the user service, and polls the loopback `/health`
endpoint for JSON `status: ok`. The shared TLS-aware launcher probe is used with
proxies bypassed. A successful health check proves basic server liveness, not
provider/chat compatibility.

Dependencies already satisfying requirements are retained. This is deliberately
not `uv sync`: unrelated Agent packages must not be pruned from a shared venv.
However pip can change a dependency and its transitive dependencies when required,
which also affects other processes sharing that environment. The script does not
update Hermes Agent's source, restart its gateway, or install optional WebUI extras.
Run only when no important chats/tasks are active; restarting interrupts WebUI work.

## Hermes-managed runtimes

Newer Hermes installations may re-enter WebUI using a base interpreter while
loading dependencies from a PM-selected generation. Installing into that base
Python or an obsolete Agent venv would target the wrong environment. The script
instead resolves the committed generation through PM's read-only selection API,
checks that its interpreter matches the live process, and verifies distribution
versions against `requirements.txt`. It does not run PM startup repair or change
the managed generation. These checks are also isolated from the caller's
`PYTHONPATH` and activated shell environment.

In this mode no dependencies are installed. Requirements are checked before the
pull and again after it, before restarting. The supported `ruamel.yaml` backend
can replace an absent PyYAML, matching WebUI's YAML compatibility layer; an
installed but too-old PyYAML is not silently accepted. URL/extra requirements
and unsupported requirements-file directives fail closed.

If a requirement is missing or too old, the script stops with an explanation:
configure a dedicated WebUI runtime or update Hermes separately. It will not
alter Hermes' dependency graph automatically. A failure after pulling leaves the
new checkout in place but does not restart the running service. Distribution
metadata checks prove declared version compatibility, not successful imports,
provider/chat compatibility, or the next release's behavior.

The script stops on pull/install/restart errors and does not reset, stash, or
rollback automatically. A failed install can leave the checkout updated and the
venv partially changed while the old service continues running. Review the error,
fix the cause, and rerun. A failure after restart requires service diagnostics:

```bash
systemctl --user status hermes-webui
journalctl --user -u hermes-webui -n 80
```

Dry-run performs local preflight checks and prints the intended commands. It
creates/acquires a lock under `.git` but does not fetch/pull, install, restart,
or contact the health endpoint. Managed-mode dry-run also verifies the current
requirements without changing PM state. It cannot prove network access or future pull
success. Untracked files are retained; Git will refuse a pull that would overwrite
them. A local helper may remain untracked without blocking updates.

## Verification

```bash
bash -n upgrade.sh
./scripts/test.sh tests/test_upgrade_script.py tests/test_tls_aware_probe.py
```

Use isolated test homes/state as described in the agent-assisted onboarding
checklist. The upgrade tests use real disposable Git repositories, real interpreters/venvs
and `/proc` runtime discovery, and a real local HTTP endpoint. They cover direct
and inline launches, wrong-checkout/unknown-code rejection, both dependency
modes, missing requirements before/after pulling, and selection loss during an
upgrade. Systemd, pip installation, and the PM selection boundary/distribution
metadata in managed-mode fixtures are simulated, so tests never restart a real
service or access a package index; they are not proof of a production upgrade.
