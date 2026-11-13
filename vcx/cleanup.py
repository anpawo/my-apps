#!/usr/bin/env python3
"""Frees the disk space agent sessions leave behind. VCX runs it after a turn (at most hourly per project) and when
a session closes: cleanup.py <cwd> [--force] [--dry-run]. --selftest checks the sweeps on a scratch tree.

Removed, each only when nothing was written inside it for its idle time and no process works in it:
- scratch over 100 MB in /tmp (any name, idle 24 h) and mktemp's tmp.* in $TMPDIR; small files are left to reboots;
- Rust incremental caches (target/**/incremental/<crate>, idle 24 h): a rebuild only recompiles the workspace crates;
- target/ and .build/ of the project's other git worktrees (idle 3 days);
- with Docker already running: dangling images, build cache over 3 days, anonymous unused volumes, and named compose
  volumes no container uses that no compose file declares, on the working tree or a branch committed in the last 7 days
  (the database an upgrade or a branch left behind)."""
import fcntl, json, os, shutil, subprocess, sys, tempfile, time

HOME = os.path.expanduser("~")
STATE = os.environ.get("VCX_CLEANUP_STATE", os.path.join(HOME, ".local/state/vcx-cleanup"))
DAY = 86400
THROTTLE = 3600
KEEP_TMP = ("claude", "com.apple", "tmux-", "launch-", "ssh-", "vcx", "fleet", "powerlog", ".")
BUILD_DIRS = ("target", ".build")
dry = "--dry-run" in sys.argv
freed = []


def run(*cmd, cwd=None, timeout=60):
    try:
        return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.SubprocessError):
        return None


def out(*cmd, cwd=None, timeout=60):
    result = run(*cmd, cwd=cwd, timeout=timeout)
    return result.stdout.strip() if result and result.returncode == 0 else ""


def written_within(path, seconds):
    cutoff = time.time() - seconds
    try:
        if os.lstat(path).st_mtime > cutoff:
            return True
    except OSError:
        return True
    for root, dirs, files in os.walk(path):
        for name in dirs + files:
            try:
                if os.lstat(os.path.join(root, name)).st_mtime > cutoff:
                    return True
            except OSError:
                pass
    return False


def process_dirs():
    lines = out("/usr/sbin/lsof", "-n", "-d", "cwd", "-Fn", timeout=30).splitlines()
    return [os.path.realpath(line[1:]) for line in lines if line.startswith("n/")]


def busy(path, cwds):
    real = os.path.realpath(path)
    return any(c == real or c.startswith(real + "/") for c in cwds)


def size_kb(path):
    text = out("/usr/bin/du", "-sk", path, timeout=300)
    return int(text.split()[0]) if text else 0


def remove(path, why, kb=None):
    kb = size_kb(path) if kb is None else kb
    freed.append((kb, path, why))
    if dry:
        return
    if os.path.isdir(path) and not os.path.islink(path):
        shutil.rmtree(path, ignore_errors=True)
    else:
        try:
            os.remove(path)
        except OSError:
            pass


def sweep_tmp(roots, cwds, idle=DAY, min_kb=100 * 1024):
    uid = os.getuid()
    for root, pattern in roots:
        try:
            names = os.listdir(root)
        except OSError:
            continue
        for name in names:
            path = os.path.join(root, name)
            if name.startswith(KEEP_TMP) or (pattern and not name.startswith(pattern)):
                continue
            try:
                st = os.lstat(path)
            except OSError:
                continue
            is_dir, is_file = os.path.isdir(path) and not os.path.islink(path), os.path.isfile(path) and not os.path.islink(path)
            if st.st_uid != uid or not (is_dir or is_file) or written_within(path, idle) or busy(path, cwds):
                continue
            kb = size_kb(path)
            if kb >= min_kb:
                remove(path, "idle scratch", kb)


def target_dirs(top, depth=4):
    for root, dirs, _ in os.walk(top):
        if root[len(top):].count(os.sep) >= depth:
            dirs[:] = []
            continue
        dirs[:] = [d for d in dirs if d not in (".git", "node_modules", ".build")]
        if "target" in dirs and os.path.exists(os.path.join(root, "target", "CACHEDIR.TAG")):
            yield os.path.join(root, "target")
            dirs.remove("target")


def sweep_incremental(top, idle=DAY):
    for target in target_dirs(top):
        for root, dirs, _ in os.walk(target):
            if os.path.basename(root) == "incremental":
                for name in dirs:
                    path = os.path.join(root, name)
                    if not written_within(path, idle):
                        remove(path, "idle Rust incremental cache")
                dirs[:] = []
            elif root[len(target):].count(os.sep) >= 3:
                dirs[:] = []


def sweep_worktrees(repo, own, cwds, idle=3 * DAY):
    run("/usr/bin/git", "-C", repo, "worktree", "prune")
    paths = [line[9:] for line in out("/usr/bin/git", "-C", repo, "worktree", "list", "--porcelain").splitlines() if line.startswith("worktree ")]
    for tree in paths:
        if os.path.realpath(tree) == os.path.realpath(own):
            continue
        for name in BUILD_DIRS:
            path = os.path.join(tree, name)
            if os.path.isdir(path) and not busy(tree, cwds) and not written_within(path, idle):
                remove(path, "idle build folder of another worktree")


def declared(volume_key, workdir):
    def says(text):
        return any(line.strip().rstrip(":") == volume_key or line.strip().startswith(volume_key + ":") for line in text.splitlines())
    for name in os.listdir(workdir):
        if "compose" in name and name.endswith((".yml", ".yaml")):
            try:
                if says(open(os.path.join(workdir, name)).read()):
                    return True
            except OSError:
                pass
    since = time.time() - 7 * DAY
    for line in out("/usr/bin/git", "-C", workdir, "for-each-ref", "--format=%(committerdate:unix) %(refname)", "refs/heads").splitlines():
        stamp, ref = line.split(" ", 1)
        if int(stamp) < since:
            continue
        files = out("/usr/bin/git", "-C", workdir, "ls-tree", "--name-only", ref).splitlines()
        for name in files:
            if "compose" in name and name.endswith((".yml", ".yaml")) and says(out("/usr/bin/git", "-C", workdir, "show", f"{ref}:{name}")):
                return True
    return False


def sweep_docker():
    docker = shutil.which("docker") or "/usr/local/bin/docker"
    if not out(docker, "info", "--format", "{{.ServerVersion}}", timeout=10):
        return
    for cmd in () if dry else (("image", "prune", "-f"), ("builder", "prune", "-f", "--filter", "until=72h"), ("volume", "prune", "-f")):
        result = run(docker, *cmd, timeout=300)
        if result and "reclaimed" in result.stdout:
            freed.append((0, "docker " + " ".join(cmd[:2]), result.stdout.strip().splitlines()[-1]))
    for name in out(docker, "volume", "ls", "-q", "--filter", "dangling=true").splitlines():
        info = json.loads(out(docker, "volume", "inspect", name) or "[{}]")[0]
        labels = info.get("Labels") or {}
        workdir, key = labels.get("com.docker.compose.project.working_dir"), labels.get("com.docker.compose.volume")
        if not workdir or not key:
            continue
        if not os.path.isdir(workdir) or not declared(key, workdir):
            result = None if dry else run(docker, "volume", "rm", name)
            if dry or (result and result.returncode == 0):
                freed.append((0, "docker volume " + name, "orphaned compose volume (no recent branch declares it)"))


def throttled(key, force):
    os.makedirs(STATE, exist_ok=True)
    stamp = os.path.join(STATE, key.strip("/").replace("/", "_") or "root")
    try:
        if not force and time.time() - os.path.getmtime(stamp) < THROTTLE:
            return True
    except OSError:
        pass
    open(stamp, "w").close()
    return False


def main():
    cwd = os.path.realpath(next((a for a in sys.argv[1:] if not a.startswith("--")), os.getcwd()))
    force = "--force" in sys.argv or dry
    os.makedirs(STATE, exist_ok=True)
    lock = open(os.path.join(STATE, "lock"), "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        return
    cwds = process_dirs()
    if not throttled("_global", force):
        sweep_tmp([("/private/tmp", None), (tempfile.gettempdir(), "tmp.")], cwds)
        sweep_docker()
    repo = out("/usr/bin/git", "-C", cwd, "rev-parse", "--show-toplevel")
    if repo and repo != HOME and not throttled(repo, force):
        common = os.path.dirname(os.path.realpath(os.path.join(repo, out("/usr/bin/git", "-C", repo, "rev-parse", "--git-common-dir"))))
        sweep_incremental(repo)
        sweep_worktrees(common, repo, cwds)
    total = sum(kb for kb, _, _ in freed)
    lines = [f"{time.strftime('%Y-%m-%d %H:%M')} {'would free' if dry else 'freed'} {kb / 1048576:.2f} GB {path} ({why})" for kb, path, why in freed]
    if lines and not dry:
        with open(os.path.join(STATE, "log"), "a") as log:
            log.write("\n".join(lines) + "\n")
    print("\n".join(lines + [f"total {total / 1048576:.2f} GB"]))


def selftest():
    global dry
    dry = False
    root = tempfile.mkdtemp()
    old = time.time() - 2 * DAY

    def make(path, age=None):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        open(path, "w").write("x")
        if age:
            os.utime(path, (age, age))
            os.utime(os.path.dirname(path), (age, age))

    make(f"{root}/tmp/stale/a/file", old); os.utime(f"{root}/tmp/stale", (old, old))
    make(f"{root}/tmp/fresh/file")
    make(f"{root}/tmp/claude-501/file", old); os.utime(f"{root}/tmp/claude-501", (old, old))
    make(f"{root}/tmp/busy/file", old); os.utime(f"{root}/tmp/busy", (old, old))
    sweep_tmp([(f"{root}/tmp", None)], [os.path.realpath(f"{root}/tmp/busy")], min_kb=0)
    assert not os.path.exists(f"{root}/tmp/stale") and os.path.exists(f"{root}/tmp/fresh"), "tmp sweep"
    assert os.path.exists(f"{root}/tmp/claude-501") and os.path.exists(f"{root}/tmp/busy"), "tmp keeps"
    make(f"{root}/repo/target/CACHEDIR.TAG")
    make(f"{root}/repo/target/debug/incremental/old-1/s/f", old)
    for p in ("old-1/s", "old-1"):
        os.utime(f"{root}/repo/target/debug/incremental/{p}", (old, old))
    make(f"{root}/repo/target/debug/incremental/new-2/s/f")
    make(f"{root}/repo/target/debug/deps/libx.rlib", old)
    sweep_incremental(f"{root}/repo")
    assert not os.path.exists(f"{root}/repo/target/debug/incremental/old-1"), "old incremental removed"
    assert os.path.exists(f"{root}/repo/target/debug/incremental/new-2") and os.path.exists(f"{root}/repo/target/debug/deps/libx.rlib"), "keeps deps"
    open(f"{root}/repo/docker-compose.yml", "w").write("volumes:\n  db-data-pg17:\n")
    assert declared("db-data-pg17", f"{root}/repo") and not declared("db-data", f"{root}/repo"), "compose declaration"
    shutil.rmtree(root)
    print("selftest ok")


if __name__ == "__main__":
    selftest() if "--selftest" in sys.argv else main()
