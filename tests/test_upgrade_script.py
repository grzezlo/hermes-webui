"""Exercise upgrade.sh with a disposable Git remote and simulated user service."""
import http.server
from contextlib import contextmanager

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import threading
import venv

import pytest
import packaging

ROOT = Path(__file__).resolve().parents[1]
pytestmark = pytest.mark.skipif(
    sys.platform != "linux" or (hasattr(os, "geteuid") and os.geteuid() == 0),
    reason="upgrade.sh requires a non-root Linux systemd user service",
)


def git(*args, cwd):
    return subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True, text=True)


@pytest.fixture
def upgrade_env(tmp_path):
    remote = tmp_path / "remote.git"
    git("init", "--bare", str(remote), cwd=tmp_path)
    source = tmp_path / "source"
    git("clone", str(remote), str(source), cwd=tmp_path)
    git("config", "user.email", "test@example.invalid", cwd=source)
    git("config", "user.name", "Test", cwd=source)
    (source / "requirements.txt").write_text("pyyaml>=6.0\n")
    (source / "server.py").write_text("import time\ntime.sleep(120)\n")
    git("add", ".", cwd=source)
    git("commit", "-m", "initial", cwd=source)
    git("push", "origin", "HEAD", cwd=source)
    repo = tmp_path / "checkout"
    git("clone", str(remote), str(repo), cwd=tmp_path)
    if (ROOT / "upgrade.sh").exists():
        shutil.copy2(ROOT / "upgrade.sh", repo / "upgrade.sh")
    (repo / "scripts/lib").mkdir(parents=True)
    shutil.copy2(ROOT / "scripts/lib/health_probe.sh", repo / "scripts/lib/health_probe.sh")
    (source / "requirements.txt").write_text("pyyaml>=6.0\ncryptography>=42.0\n")
    git("add", ".", cwd=source)
    git("commit", "-m", "new dependency", cwd=source)
    git("push", "origin", "HEAD", cwd=source)
    bindir = tmp_path / "bin"
    bindir.mkdir()
    log = tmp_path / "calls.jsonl"
    # Fake only external systemd/pip boundaries; Git and /health are real.
    service = bindir / "systemctl"
    service.write_text("#!" + sys.executable + "\n" + '''import json, os, sys
from pathlib import Path
args = sys.argv[1:]
with open(os.environ['CALL_LOG'], 'a') as f:
    f.write(json.dumps(['systemctl', *args]) + '\\n')
if 'show' in args:
    override = os.environ.get('SERVICE_PID_FILE')
    print(Path(override).read_text().strip() if override and Path(override).is_file() else os.environ['SERVICE_PID'])
elif 'is-active' in args:
    sys.exit(0)
elif 'restart' in args:
    sys.exit(int(os.environ.get('RESTART_FAIL', '0')))
else:
    sys.exit(1)
''')
    service.chmod(0o755)
    runtime_dir = tmp_path / "runtime-venv"
    venv.EnvBuilder(with_pip=False).create(runtime_dir)
    python = runtime_dir / "bin/python"
    site = next((runtime_dir / "lib").glob("python*/site-packages"))
    (site / "pip.py").write_text('''import json, os, sys
with open(os.environ['CALL_LOG'], 'a') as f:
    f.write(json.dumps(['runtime', '-m', 'pip', *sys.argv[1:]]) + '\\n')
sys.exit(int(os.environ.get('PIP_FAIL', '0')) if 'install' in sys.argv else 0)
''')

    class Health(http.server.BaseHTTPRequestHandler):
        def do_GET(self):  # noqa: N802
            self.send_response(200)
            self.end_headers()
            self.wfile.write(json.dumps({"status": os.environ.get("FIXTURE_HEALTH", "ok")}).encode())

        def log_message(self, format, *args):
            pass

    httpd = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Health)
    thread = threading.Thread(target=httpd.serve_forever, daemon=True)
    thread.start()
    runtime_env = {"PATH": os.environ["PATH"], "HERMES_WEBUI_HOST": "127.0.0.1",
                   "HERMES_WEBUI_PORT": str(httpd.server_port)}
    # A real /proc cmdline with the same shape as the WebUI interpreter/server.
    runtime = subprocess.Popen([str(python), str(repo / "server.py")], env=runtime_env)
    env = {"PATH": str(bindir) + os.pathsep + os.environ["PATH"], "HOME": str(tmp_path),
           "TMPDIR": str(tmp_path), "CALL_LOG": str(log), "SERVICE_PID": str(runtime.pid),
           "HERMES_WEBUI_HOST": "127.0.0.1", "HERMES_WEBUI_PORT": str(httpd.server_port),
           "HERMES_HOME": str(tmp_path / "home"), "HERMES_WEBUI_STATE_DIR": str(tmp_path / "state")}
    try:
        yield repo, env, log
    finally:
        runtime.terminate()
        runtime.wait(timeout=5)
        httpd.shutdown()
        httpd.server_close()
        thread.join(timeout=5)


def run_upgrade(fixture, *args, **overrides):
    repo, env, _ = fixture
    return subprocess.run(["bash", str(repo / "upgrade.sh"), *args], cwd=repo,
                          env={**env, **overrides}, capture_output=True, text=True, timeout=50)


def calls(fixture):
    path = fixture[2]
    return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []


@contextmanager
def inline_runtime(fixture, *, target=None, python=None, code=None):
    repo, env, _ = fixture
    target = str(target or repo / "server.py")
    agent = repo.parent / "agent"
    agent.mkdir(exist_ok=True)
    (agent / "run_agent.py").touch()
    # Shape emitted by Hermes' hermes_cli.venv_sync.relaunch_command.
    code = code or (
        f"import sys, runpy; sys.path.insert(0, {str(agent)!r}); "
        f"sys.argv = {[target]!r}; runpy.run_path({target!r}, run_name='__main__')"
    )
    python = python or repo.parent / "runtime-venv/bin/python"
    runtime = subprocess.Popen([str(python), "-I", "-c", code], env=env)
    try:
        yield str(runtime.pid)
    finally:
        runtime.terminate()
        runtime.wait(timeout=5)


def test_dry_run_recognizes_hermes_inline_venv_runtime(upgrade_env):
    with inline_runtime(upgrade_env) as pid:
        result = run_upgrade(upgrade_env, "--dry-run", SERVICE_PID=pid)
    assert result.returncode == 0, result.stdout + result.stderr
    assert str(upgrade_env[0].parent / "runtime-venv/bin/python") in result.stdout
    assert not any("install" in call or "restart" in call for call in calls(upgrade_env))


@pytest.fixture
def managed_runtime(upgrade_env):
    agent = upgrade_env[0].parent / "agent"
    agent.mkdir()
    (agent / "run_agent.py").touch()
    generation = agent / "generation"
    venv.EnvBuilder(with_pip=False, symlinks=True).create(generation)
    site = next((generation / "lib").glob("python*/site-packages"))
    shutil.copytree(Path(packaging.__file__).parent, site / "packaging")
    # Disposable distribution metadata, not real package downloads/PM state.
    for name, version in (("pyyaml", "6.0"), ("cryptography", "42.0")):
        info = site / f"{name}-{version}.dist-info"
        info.mkdir()
        (info / "METADATA").write_text(f"Metadata-Version: 2.1\nName: {name}\nVersion: {version}\n")
    pm = agent / "pm"
    pm.mkdir()
    (pm / "__init__.py").touch()
    # Only the read-only PM selection boundary is simulated.
    (pm / "environments.py").write_text(
        "from pathlib import Path\n"
        "def committed_venv(root): return Path(root) / 'generation'\n"
        f"def site_packages(root): return Path(root) / {str(site.relative_to(generation))!r}\n"
        "def venv_python(root): return Path(root) / 'bin/python'\n"
    )
    return Path(sys.executable).resolve(), site


def test_managed_runtime_checks_dependencies_without_pip(upgrade_env, managed_runtime):
    with inline_runtime(upgrade_env, python=managed_runtime[0]) as pid:
        result = run_upgrade(upgrade_env, "--dry-run", SERVICE_PID=pid)
    assert result.returncode == 0, result.stdout + result.stderr
    assert "managed" in result.stdout.lower()
    assert not any(call[0] == "runtime" or "restart" in call for call in calls(upgrade_env))


def test_inline_venv_upgrade_installs_and_restarts(upgrade_env):
    with inline_runtime(upgrade_env) as pid:
        result = run_upgrade(upgrade_env, SERVICE_PID=pid)
    assert result.returncode == 0, result.stdout + result.stderr
    assert any(call[:4] == ["runtime", "-m", "pip", "install"] for call in calls(upgrade_env))
    assert "Health: ok" in result.stdout


def test_managed_upgrade_pulls_and_restarts_without_installing(upgrade_env, managed_runtime):
    with inline_runtime(upgrade_env, python=managed_runtime[0]) as pid:
        result = run_upgrade(upgrade_env, SERVICE_PID=pid)
    assert result.returncode == 0, result.stdout + result.stderr
    assert "cryptography" in (upgrade_env[0] / "requirements.txt").read_text()
    assert not any(call[0] == "runtime" for call in calls(upgrade_env))
    assert any("restart" in call for call in calls(upgrade_env))
    assert "Health: ok" in result.stdout


def test_managed_missing_initial_dependency_does_not_pull(upgrade_env, managed_runtime):
    site = managed_runtime[1]
    shutil.rmtree(site / "pyyaml-6.0.dist-info")
    before = git("rev-parse", "HEAD", cwd=upgrade_env[0]).stdout
    with inline_runtime(upgrade_env, python=managed_runtime[0]) as pid:
        result = run_upgrade(upgrade_env, SERVICE_PID=pid)
    assert result.returncode != 0
    assert "unsatisfied requirements: pyyaml>=6.0" in result.stderr
    assert git("rev-parse", "HEAD", cwd=upgrade_env[0]).stdout == before
    assert not any("restart" in call or call[0] == "runtime" for call in calls(upgrade_env))


def test_managed_missing_pulled_dependency_does_not_restart(upgrade_env, managed_runtime):
    shutil.rmtree(managed_runtime[1] / "cryptography-42.0.dist-info")
    with inline_runtime(upgrade_env, python=managed_runtime[0]) as pid:
        result = run_upgrade(upgrade_env, SERVICE_PID=pid)
    assert result.returncode != 0
    assert "cryptography>=42.0" in result.stderr
    assert "cryptography" in (upgrade_env[0] / "requirements.txt").read_text()
    assert not any("restart" in call or call[0] == "runtime" for call in calls(upgrade_env))


def test_managed_yaml_fallback_matches_webui(upgrade_env, managed_runtime):
    site = managed_runtime[1]
    shutil.rmtree(site / "pyyaml-6.0.dist-info")
    info = site / "ruamel_yaml-0.19.0.dist-info"
    info.mkdir()
    (info / "METADATA").write_text("Metadata-Version: 2.1\nName: ruamel.yaml\nVersion: 0.19.0\n")
    with inline_runtime(upgrade_env, python=managed_runtime[0]) as pid:
        result = run_upgrade(upgrade_env, "--dry-run", SERVICE_PID=pid)
    assert result.returncode == 0, result.stdout + result.stderr


@pytest.mark.parametrize("name,version,too_old", [("pyyaml", "6.0", "5.4"), ("cryptography", "42.0", "41.0")])
def test_managed_outdated_dependency_is_rejected(upgrade_env, managed_runtime, name, version, too_old):
    metadata = managed_runtime[1] / f"{name}-{version}.dist-info/METADATA"
    metadata.write_text(f"Metadata-Version: 2.1\nName: {name}\nVersion: {too_old}\n")
    with inline_runtime(upgrade_env, python=managed_runtime[0]) as pid:
        result = run_upgrade(upgrade_env, SERVICE_PID=pid)
    assert result.returncode != 0
    assert "unsatisfied requirements" in result.stderr
    assert name in result.stderr
    assert not any("restart" in call or call[0] == "runtime" for call in calls(upgrade_env))


def test_service_pid_change_after_pull_does_not_install_or_restart(upgrade_env):
    repo = upgrade_env[0]
    changed_pid = repo.parent / "changed-pid"
    hook = repo / ".git/hooks/post-merge"
    hook.write_text(f"#!/bin/sh\nprintf '0' > '{changed_pid}'\n")
    hook.chmod(0o755)
    result = run_upgrade(upgrade_env, SERVICE_PID_FILE=str(changed_pid))
    assert result.returncode != 0
    assert "Service PID changed" in result.stderr
    assert "cryptography" in (repo / "requirements.txt").read_text()
    assert not any("restart" in call or "install" in call for call in calls(upgrade_env))


def test_managed_selection_disappearing_after_pull_does_not_restart(upgrade_env, managed_runtime):
    repo = upgrade_env[0]
    generation = repo.parent / "agent/generation"
    hook = repo / ".git/hooks/post-merge"
    hook.write_text(f"#!/bin/sh\nmv '{generation}' '{generation.with_name('old-generation')}'\n")
    hook.chmod(0o755)
    with inline_runtime(upgrade_env, python=managed_runtime[0]) as pid:
        result = run_upgrade(upgrade_env, SERVICE_PID=pid)
    assert result.returncode != 0
    assert "runtime" in result.stderr.lower()
    assert not any("restart" in call or call[0] == "runtime" for call in calls(upgrade_env))


def test_inline_runtime_from_another_checkout_is_rejected(upgrade_env):
    repo = upgrade_env[0]
    target = repo.parent / "another/server.py"
    target.parent.mkdir()
    shutil.copy2(repo / "server.py", target)
    before = git("rev-parse", "HEAD", cwd=repo).stdout
    with inline_runtime(upgrade_env, target=target) as pid:
        result = run_upgrade(upgrade_env, SERVICE_PID=pid)
    assert result.returncode != 0
    assert "not running server.py from this checkout" in result.stderr
    assert git("rev-parse", "HEAD", cwd=repo).stdout == before
    assert not any(call[0] == "runtime" or "restart" in call for call in calls(upgrade_env))


@pytest.mark.parametrize("variant", ["hint_only", "extra_statement", "different_argv"])
def test_arbitrary_inline_code_is_not_used_as_runtime_proof(upgrade_env, variant):
    repo = upgrade_env[0]
    target = str(repo / "server.py")
    agent = str(repo.parent / "agent")
    if variant == "hint_only":
        code = f"import time; hint = {target!r}; time.sleep(120)"
    else:
        args = [target] if variant == "extra_statement" else ["not-the-server"]
        prefix = f"import sys, runpy; sys.path.insert(0, {agent!r}); sys.argv = {args!r}; "
        code = prefix + f"runpy.run_path({target!r}, run_name='__main__')"
        if variant == "extra_statement":
            code += "; secret = 'fixture-secret-do-not-print'"
    with inline_runtime(upgrade_env, code=code) as pid:
        result = run_upgrade(upgrade_env, SERVICE_PID=pid)
    assert result.returncode != 0
    assert "fixture-secret-do-not-print" not in result.stdout + result.stderr
    assert not any(call[0] == "runtime" or "restart" in call for call in calls(upgrade_env))


def test_unmanaged_system_interpreter_is_rejected(upgrade_env):
    with inline_runtime(upgrade_env, python=Path(sys.executable).resolve()) as pid:
        result = run_upgrade(upgrade_env, SERVICE_PID=pid)
    assert result.returncode != 0
    assert "refusing system-Python installation" in result.stderr
    assert not any(call[0] == "runtime" or "restart" in call for call in calls(upgrade_env))


def test_upgrade_pulls_installs_in_runtime_and_restarts(upgrade_env):
    result = run_upgrade(upgrade_env)
    assert result.returncode == 0, result.stdout + result.stderr
    assert "cryptography" in (upgrade_env[0] / "requirements.txt").read_text()
    invoked = calls(upgrade_env)
    install = next(i for i, call in enumerate(invoked) if call[:4] == ["runtime", "-m", "pip", "install"])
    restart = next(i for i, call in enumerate(invoked) if "restart" in call)
    assert install < restart
    assert "--upgrade" not in invoked[install]
    assert "--user" in invoked[restart]
    assert "Health: ok" in result.stdout


def test_dry_run_does_not_pull_install_or_restart(upgrade_env):
    before = git("rev-parse", "HEAD", cwd=upgrade_env[0]).stdout
    result = run_upgrade(upgrade_env, "--dry-run")
    assert result.returncode == 0, result.stdout + result.stderr
    assert git("rev-parse", "HEAD", cwd=upgrade_env[0]).stdout == before
    assert not any("install" in call or "restart" in call for call in calls(upgrade_env))
    assert "git pull --ff-only" in result.stdout
    assert "systemctl --user restart" in result.stdout


def test_dirty_checkout_is_not_updated(upgrade_env):
    (upgrade_env[0] / "requirements.txt").write_text("# local change\n")
    result = run_upgrade(upgrade_env)
    assert result.returncode != 0
    assert "Tracked local changes" in result.stderr
    assert not calls(upgrade_env)


def test_diverged_branch_is_not_reset(upgrade_env):
    repo = upgrade_env[0]
    git("config", "user.email", "test@example.invalid", cwd=repo)
    git("config", "user.name", "Test", cwd=repo)
    (repo / "local.txt").write_text("keep me\n")
    git("add", "local.txt", cwd=repo)
    git("commit", "-m", "local commit", cwd=repo)
    before = git("rev-parse", "HEAD", cwd=repo).stdout
    result = run_upgrade(upgrade_env)
    assert result.returncode != 0
    assert git("rev-parse", "HEAD", cwd=repo).stdout == before
    assert not any("install" in call or "restart" in call for call in calls(upgrade_env))


def test_install_failure_does_not_restart_service(upgrade_env):
    result = run_upgrade(upgrade_env, PIP_FAIL="1")
    assert result.returncode != 0
    assert "dependency installation" in result.stderr
    assert not any("restart" in call for call in calls(upgrade_env))


def test_restart_failure_is_not_reported_as_success(upgrade_env):
    result = run_upgrade(upgrade_env, RESTART_FAIL="1")
    assert result.returncode != 0
    assert "service restart" in result.stderr
    assert "Health: ok" not in result.stdout


def test_unknown_runtime_is_rejected_before_pull(upgrade_env):
    before = git("rev-parse", "HEAD", cwd=upgrade_env[0]).stdout
    result = run_upgrade(upgrade_env, SERVICE_PID="0")
    assert result.returncode != 0
    assert "Cannot identify service PID" in result.stderr
    assert git("rev-parse", "HEAD", cwd=upgrade_env[0]).stdout == before


def test_concurrent_upgrade_is_rejected(upgrade_env):
    import fcntl

    lock = upgrade_env[0] / ".git/hermes-webui-upgrade.lock"
    with lock.open("w") as handle:
        fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        result = run_upgrade(upgrade_env)
    assert result.returncode != 0
    assert "Another upgrade" in result.stderr
    assert not calls(upgrade_env)


def test_unhealthy_http_200_is_not_success(upgrade_env, monkeypatch):
    monkeypatch.setenv("FIXTURE_HEALTH", "degraded")
    result = run_upgrade(upgrade_env)
    assert result.returncode != 0
    assert "Health check failed" in result.stderr
    assert "Health: ok" not in result.stdout
