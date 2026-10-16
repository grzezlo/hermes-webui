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

Outside the daily branch (below), the update follows the current branch's configured
Git upstream with `git pull --ff-only`; it does not select the WebUI Settings stable/experimental
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
creates/acquires a lock under `.git` (and, for daily, a temporary worktree that it
removes) but does not fetch/pull, install, restart,
or contact the health endpoint. Managed-mode dry-run also verifies the current
requirements without changing PM state. It cannot prove network access or future pull
success. Untracked files are retained; Git will refuse a pull that would overwrite
them. A local helper may remain untracked without blocking updates.

## Daily integration branch

A personal checkout can run more than upstream: `daily` is `upstream/master`
plus the `gz/tools` branch (this script, its docs and tests, the launcher and the
recipe) plus topic branches such as open PRs. It is never edited or pushed by
hand; it is always regenerated, so everything it contains must live on another
branch (topic branches from other people's forks should be copied to your own).

The recipe `daily.topics` on `gz/tools` lists local topic branches, one per line,
merged in order. `#` starts a comment.

```text
fix/session-row-keyboard-activation   # PR #8214
```

With `daily` checked out, `upgrade.sh`:

1. reads the recipe from the `gz/tools` ref (not from the working tree) and
   checks every listed branch exists;
2. runs `git fetch --no-tags upstream master`;
3. builds the new daily in a temporary `git worktree`: `upstream/master`, then
   `gz/tools`, then each topic as its own `daily: merge <topic>` merge commit,
   with `rerere` replaying recorded conflict resolutions;
4. reports a topic that is already in `upstream/master`, so it can be removed
   from the recipe once its PR is merged;
5. stops on a conflict rerere cannot resolve, removes the worktree and leaves
   the checkout, `daily` and the service untouched;
6. stops without switching or restarting when the build has the same content
   as the current `daily`;
7. otherwise switches the checkout with `git switch -C daily`, keeps the
   replaced build as `daily-prev`, installs or checks requirements, restarts
   and checks `/health` exactly as in the ordinary mode.

A failed switch (for example an untracked file in the way) leaves `daily`
unchanged and does not restart. `--rollback` switches `daily` and `daily-prev`
and restarts; a second rollback returns to where you were. On a branch listed in
the recipe the script refuses to run, because pulling a PR branch is rarely what
an upgrade means; `--switch-to-daily` builds and switches from any branch.
`--dry-run` makes a trial build from the current refs without fetching, then
discards it.

The whole script is a single compound command, so Bash parses all of it before
the switch can replace the file. Git replaces files rather than rewriting them in
place, so a running copy is normally safe anyway; this is defence in depth.

### Resolving a new conflict

Enable rerere once (`git config rerere.enabled true`), then reproduce the build
in a scratch worktree, resolve and commit; rerere records the resolution and the
next run reuses it:

```bash
git worktree add --detach ../daily-resolve upstream/master
cd ../daily-resolve
git merge --no-edit gz/tools
git merge --no-edit <earlier topics...>
git merge --no-edit <conflicting topic>   # resolve, git add, git commit
cd - && git worktree remove ../daily-resolve
```

Recorded resolutions live in `.git/rr-cache` and are local. If a conflict is
permanent, commit its resolution as a small topic branch listed after both
sides instead.

### Launcher

A PR branch made from master has no `upgrade.sh`. The `hermes-upgrade` launcher
extracts the current script from `gz/tools` into a temporary directory and runs
it with `--repo`, so it works whatever is checked out. Install a copy outside
the checkout:

```bash
git show gz/tools:hermes-upgrade > ~/.local/bin/hermes-upgrade
chmod +x ~/.local/bin/hermes-upgrade
hermes-upgrade --dry-run
```

It uses `$HERMES_WEBUI_REPO` (default `~/hermes-webui`) and
`$HERMES_UPGRADE_TOOLS_BRANCH` (default `gz/tools`). Reinstall the copy when the
launcher itself changes; changes to `upgrade.sh` need no reinstall.

## Verification

```bash
bash -n upgrade.sh
./scripts/test.sh tests/test_upgrade_script.py tests/test_tls_aware_probe.py
```

The daily tests build real recipes, conflicts, rerere replays, rollbacks and
blocked switches in disposable repositories, and run the launcher against a
tools branch.

Use isolated test homes/state as described in the agent-assisted onboarding
checklist. The upgrade tests use real disposable Git repositories, real interpreters/venvs
and `/proc` runtime discovery, and a real local HTTP endpoint. They cover direct
and inline launches, wrong-checkout/unknown-code rejection, both dependency
modes, missing requirements before/after pulling, and selection loss during an
upgrade. Systemd, pip installation, and the PM selection boundary/distribution
metadata in managed-mode fixtures are simulated, so tests never restart a real
service or access a package index; they are not proof of a production upgrade.
