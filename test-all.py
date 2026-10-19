#!/usr/bin/env python3
"""Run the Hermes WebUI test suite in memory-safe chunks and summarise it.

The whole suite does not fit in one pytest process on a small box: collecting
it alone takes ~2.5 GB, because hundreds of test modules keep the big static
files in module-level strings. This runs the suite as sequential chunks, each
in its own process under a systemd memory cap (an OOM kills the chunk, never
the live service), with HOME pointed at a throwaway directory (a real HOME lets
the test servers adopt ~/.hermes/hermes-agent, which then installs a private
runtime per test data root and breaks startup).

Failures are then classified without manual work:
  * every failing file is rerun alone (order-dependent vs. failing on its own);
  * the same chunk is rerun on a baseline ref (default: upstream/master) in a
    temporary worktree, so failures that already exist there are marked as such.

Usage:
  hermes-webui-test-all [options] [test files...]   (launcher: hermes-webui-test-all on gz/tools)

  With no files, runs every tests/test_*.py. Options:
    --repo PATH        repository (default: the git checkout containing cwd)
    --chunk N          files per chunk (default 40)
    --browser          also run the browser gates listed in the CI workflow
    --only-browser     run only the browser gates
    --baseline REF     ref to compare failures against (default upstream/master,
                       falling back to origin/master); --no-baseline to skip
    --mem-max SIZE     RAM cap per chunk (default 1800M); --swap-max (default 1G)
    --timeout SEC      wall-clock limit per chunk (default 900)

Exit status: 0 no new failures, 1 new failures, 2 infrastructure problem
(chunk could not run: OOM even alone, timeout, setup error).
Logs: ~/.cache/hermes-webui-test-all/<timestamp>/ (last 5 runs kept).
"""
import argparse
import fcntl
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

REAL_HOME = Path.home()
CACHE = REAL_HOME / ".cache" / "hermes-webui-test-all"
KEEP_RUNS = 5
HAVE_SCOPE = shutil.which("systemd-run") is not None and subprocess.run(
    ["systemd-run", "--user", "--scope", "--quiet", "true"],
    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
).returncode == 0

SUMMARY_RE = re.compile(r"^=*\s*((?:\d+ [\w ]+?(?:, )?)+) in [\d.]+s", re.M)
COUNT_RE = re.compile(r"(\d+) (passed|failed|errors?|skipped|xfailed|xpassed)")
FAIL_RE = re.compile(r"^(FAILED|ERROR) (\S+)")


def fail_setup(msg):
    print(f"hermes-webui-test-all: {msg}", file=sys.stderr)
    sys.exit(2)


def log(msg):
    print(msg, flush=True)


class Runner:
    def __init__(self, args, run_dir):
        self.args = args
        self.run_dir = run_dir
        self.seq = 0
        self.home = Path(tempfile.mkdtemp(prefix="home-", dir=run_dir))
        (self.home / "workspace").mkdir()
        (self.home / "Downloads").mkdir()
        self.env = dict(os.environ)
        self.env["HOME"] = str(self.home)
        pw = REAL_HOME / ".cache" / "ms-playwright"
        if "PLAYWRIGHT_BROWSERS_PATH" not in self.env and pw.is_dir():
            self.env["PLAYWRIGHT_BROWSERS_PATH"] = str(pw)
        for k in ("TMPDIR", "TMP", "TEMP", "HERMES_HOME", "HERMES_BASE_HOME",
                  "HERMES_WEBUI_STATE_DIR", "HERMES_WEBUI_AGENT_DIR"):
            self.env.pop(k, None)

    def run(self, cmd, cwd, name):
        """Run cmd under a memory-capped scope. Returns (rc, output, oom, timed_out)."""
        self.seq += 1
        unit = f"hwta-{os.getpid()}-{self.seq}"
        full = ["timeout", "--kill-after=30", str(self.args.timeout)] + cmd
        if HAVE_SCOPE:
            full = ["systemd-run", "--user", "--scope", "--quiet", f"--unit={unit}",
                    "-p", f"MemoryMax={self.args.mem_max}",
                    "-p", f"MemorySwapMax={self.args.swap_max}", "--"] + full
        logfile = self.run_dir / f"{self.seq:03d}-{name}.log"
        with open(logfile, "w") as fh:
            fh.write("$ " + " ".join(cmd) + f"\n# cwd: {cwd}\n")
            fh.flush()
            rc = subprocess.run(full, cwd=cwd, env=self.env, stdout=fh,
                                stderr=subprocess.STDOUT).returncode
        out = logfile.read_text(errors="replace")
        timed_out = rc == 124
        oom = False
        if rc in (137, 143, -9, -15) and HAVE_SCOPE:
            time.sleep(1)
            j = subprocess.run(["journalctl", "--user", "-u", f"{unit}.scope", "--no-pager", "-q"],
                               capture_output=True, text=True).stdout
            oom = "oom-kill" in j or "OOM killer" in j
        elif rc in (137, -9):
            oom = True
        return rc, out, oom, timed_out


def parse_pytest(out):
    counts = {}
    m = None
    for m in SUMMARY_RE.finditer(out):
        pass
    if m:
        for n, kind in COUNT_RE.findall(m.group(1)):
            kind = "errors" if kind.startswith("error") else kind
            counts[kind] = counts.get(kind, 0) + int(n)
    fails = []
    for line in out.splitlines():
        f = FAIL_RE.match(line)
        if f and f.group(2) not in fails:
            fails.append(f.group(2))
    return counts, fails


def pytest_cmd(repo, files):
    return [str(repo / "scripts" / "test.sh"), *files, "-q", "-rfE",
            "-p", "no:cacheprovider", "--timeout=120"]


def run_chunk(runner, repo, cwd, files, label):
    """Run files as one pytest process; halve on OOM. Returns list of results."""
    rc, out, oom, timed_out = runner.run(pytest_cmd(repo, files), cwd, label)
    if oom and len(files) > 1:
        half = len(files) // 2
        log(f"  {label}: out of memory with {len(files)} files, splitting")
        return (run_chunk(runner, repo, cwd, files[:half], label + "a")
                + run_chunk(runner, repo, cwd, files[half:], label + "b"))
    counts, fails = parse_pytest(out)
    problem = None
    if oom:
        problem = "out of memory even alone"
    elif timed_out:
        problem = f"timed out after {runner.args.timeout}s"
    elif rc not in (0, 1) and not counts:
        problem = f"exited {rc} without a pytest summary"
    elif rc == 1 and not fails:
        problem = "pytest reported failure but no FAILED/ERROR lines"
    return [{"label": label, "files": files, "rc": rc, "counts": counts,
             "fails": fails, "problem": problem}]


def ci_gates(repo):
    wf = repo / ".github" / "workflows" / "browser-smoke.yml"
    if not wf.is_file():
        return sorted(p.name for p in (repo / "tests").glob("browser_*.py"))
    return re.findall(r"run:\s*python\s+tests/(browser_\w+\.py)", wf.read_text())


def resolve_baseline(repo, args):
    if args.no_baseline:
        return None
    for ref in ([args.baseline] if args.baseline else ["upstream/master", "origin/master"]):
        if subprocess.run(["git", "-C", str(repo), "rev-parse", "--verify", "-q", ref + "^{commit}"],
                          capture_output=True).returncode == 0:
            return ref
    return None


def prune_old_runs():
    runs = sorted(p for p in CACHE.iterdir() if p.is_dir())
    for old in runs[:-KEEP_RUNS]:
        shutil.rmtree(old, ignore_errors=True)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("files", nargs="*")
    ap.add_argument("--repo")
    ap.add_argument("--chunk", type=int, default=40)
    ap.add_argument("--browser", action="store_true")
    ap.add_argument("--only-browser", action="store_true")
    ap.add_argument("--baseline")
    ap.add_argument("--no-baseline", action="store_true")
    ap.add_argument("--mem-max", default="1800M")
    ap.add_argument("--swap-max", default="1G")
    ap.add_argument("--timeout", type=int, default=900)
    args = ap.parse_args()

    start = Path(args.repo or os.getcwd())
    top = subprocess.run(["git", "-C", str(start), "rev-parse", "--show-toplevel"],
                         capture_output=True, text=True)
    if top.returncode != 0:
        fail_setup(f"not inside a git checkout: {start}")
    repo = Path(top.stdout.strip())
    if not (repo / "scripts" / "test.sh").is_file():
        fail_setup(f"{repo} does not look like hermes-webui (no scripts/test.sh)")

    CACHE.mkdir(parents=True, exist_ok=True)
    lock = open(CACHE / ".lock", "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        fail_setup("another hermes-webui-test-all run is in progress")
    prune_old_runs()
    run_dir = CACHE / time.strftime("%Y%m%d-%H%M%S")
    run_dir.mkdir()
    runner = Runner(args, run_dir)

    head = subprocess.run(["git", "-C", str(repo), "log", "-1", "--format=%h %s"],
                          capture_output=True, text=True).stdout.strip()
    branch = subprocess.run(["git", "-C", str(repo), "branch", "--show-current"],
                            capture_output=True, text=True).stdout.strip() or "(detached)"
    dirty = bool(subprocess.run(["git", "-C", str(repo), "status", "--porcelain", "-uno"],
                                capture_output=True, text=True).stdout.strip())
    log(f"hermes-webui-test-all: {repo} on {branch} at {head}{' + uncommitted changes' if dirty else ''}")
    log(f"logs: {run_dir}" + ("" if HAVE_SCOPE else "  (no systemd --user scope: running without memory cap)"))

    if args.files:
        files = [os.path.relpath(Path(f).resolve(), repo) for f in args.files]
    elif args.only_browser:
        files = []
    else:
        files = sorted(str(p.relative_to(repo)) for p in (repo / "tests").glob("test_*.py"))

    t0 = time.time()
    results = []
    chunks = [files[i:i + args.chunk] for i in range(0, len(files), args.chunk)]
    for n, chunk in enumerate(chunks, 1):
        label = f"chunk{n:02d}"
        for r in run_chunk(runner, repo, repo, chunk, label):
            results.append(r)
            c = r["counts"]
            state = r["problem"] or ("ok" if not r["fails"] else f"{len(r['fails'])} failing")
            log(f"[{n}/{len(chunks)}] {r['label']}: {c.get('passed', 0)} passed, "
                f"{c.get('failed', 0)} failed, {c.get('errors', 0)} errors, "
                f"{c.get('skipped', 0)} skipped - {state}")

    gate_results = []
    if args.browser or args.only_browser:
        for gate in ci_gates(repo):
            rc, out, oom, timed_out = runner.run(
                [str(repo / ".venv" / "bin" / "python"), f"tests/{gate}"], repo, gate[:-3])
            last = next((l for l in reversed(out.strip().splitlines()) if l.strip()), "")
            ok = rc == 0
            why = "out of memory" if oom else "timed out" if timed_out else last[:160]
            gate_results.append((gate, ok, why))
            log(f"gate {gate}: {'PASS' if ok else 'FAIL'} - {why}")

    # Classify failures.
    failing = [r for r in results if r["fails"]]
    alone = {}
    for r in failing:
        files_failing = sorted({f.split("::")[0] for f in r["fails"]})
        for f in files_failing:
            rc, out, oom, timed_out = runner.run(pytest_cmd(repo, [f]), repo, "alone-" + Path(f).stem)
            _, fails_alone = parse_pytest(out)
            for t in r["fails"]:
                if t.split("::")[0] == f:
                    alone[t] = t in fails_alone or (rc not in (0, 1))

    baseline = resolve_baseline(repo, args) if failing else None
    base_fails = {}
    if baseline:
        wt = Path(tempfile.mkdtemp(prefix="baseline-", dir=run_dir))
        subprocess.run(["git", "-C", str(repo), "worktree", "add", "-q", "--detach", str(wt), baseline],
                       check=True)
        try:
            for r in failing:
                present = [f for f in r["files"] if (wt / f).is_file()]
                if not present:
                    continue
                rc, out, oom, timed_out = runner.run(pytest_cmd(repo, present), wt, "baseline-" + r["label"])
                _, bf = parse_pytest(out)
                for t in r["fails"]:
                    if (wt / t.split("::")[0]).is_file():
                        base_fails[t] = t in bf
        finally:
            subprocess.run(["git", "-C", str(repo), "worktree", "remove", "--force", str(wt)])

    total = {}
    for r in results:
        for k, v in r["counts"].items():
            total[k] = total.get(k, 0) + v
    problems = [r for r in results if r["problem"]]
    new, preexisting = [], []
    lines = []
    for r in failing:
        for t in r["fails"]:
            a = "fails alone" if alone.get(t) else "passes alone (order-dependent)"
            if t in base_fails:
                b = f"also fails on {baseline}" if base_fails[t] else f"passes on {baseline}"
            else:
                b = "not on baseline" if baseline else "baseline not checked"
            (preexisting if base_fails.get(t) else new).append(t)
            lines.append(f"  {t}\n      {a}; {b} [{r['label']}]")

    mins = (time.time() - t0) / 60
    out = [f"\n=== Summary ({mins:.1f} min, {len(files)} files) ===",
           "  " + ", ".join(f"{v} {k}" for k, v in sorted(total.items())) if total else "  no pytest results"]
    if lines:
        out.append("Failures:")
        out.extend(lines)
    for r in problems:
        out.append(f"PROBLEM {r['label']}: {r['problem']} ({len(r['files'])} files: {r['files'][0]} ...)")
    for gate, ok, why in gate_results:
        if not ok:
            out.append(f"GATE FAIL {gate}: {why}")
    verdict = (2 if problems else 1 if new or any(not ok for _, ok, _ in gate_results) else 0)
    out.append({0: "RESULT: no new failures" + (f" ({len(preexisting)} pre-existing on {baseline})" if preexisting else ""),
                1: f"RESULT: {len(new)} new failing test(s)" + ("" if not gate_results else
                   f", {sum(not ok for _, ok, _ in gate_results)} failing gate(s)"),
                2: "RESULT: incomplete - see PROBLEM lines"}[verdict])
    text = "\n".join(out)
    log(text)
    (run_dir / "summary.txt").write_text(text + "\n")
    shutil.rmtree(runner.home, ignore_errors=True)
    return verdict


if __name__ == "__main__":
    sys.exit(main())
