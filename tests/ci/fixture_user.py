#!/usr/bin/env python3
"""Run a command as a lane's own non-root fixture user; own the pinned Python 3.12 environment.

Fixtures refuse root (VERIFICATION.md, Canonical gates), and cloud containers
run as root. `.agents/as-fixture-user` runs this module as root:

  .agents/as-fixture-user LANE [--ref REF] [--keep NAME]... -- COMMAND...
  .agents/as-fixture-user --remove LANE

The first run for LANE creates the user `rui-LANE` with the home /home/rui-LANE.
Root reads its own state and places what the lane needs where the lane can
read it; the lane reads nothing else, so where root keeps its checkout,
interpreter, toolchains and CA bundle never matters. Every run, under that
lane's lock:
  - root reads `Inputs`: the commit REF (default HEAD) names, this checkout's
    common git directory, origin's URL, the caller's CA bundle and the
    python3.12, zig and go the caller would run;
  - root places them (`place`): it fetches REF, origin/main and the v* tags
    (this repository's, then origin's) into a bare repository in
    /var/lib/rui-fixture/lanes/LANE, copies the CA bundle there, and uses each
    install in place when every user can reach it, otherwise a hard-linked copy
    under /var/lib/rui-fixture/tools. The lane's directory is root's and only
    the lane's group reads it, so the lane cannot change what root reads next
    run and other lanes cannot read it;
  - as that user, checks out REF at ~/rui from the placed repository and
    removes untracked files that are not ignored (ignored build caches stay);
  - keeps the Python 3.12 environment at ~/.local/share/rui/venv-3.12 current
    with the placed interpreter and with tests/ci/requirements.txt and
    tests/integration/requirements.txt at REF, rebuilding nothing unchanged;
  - runs COMMAND in ~/rui as that user under `env -i`, with only the
    variables `environment` names, and exits with its status.
Lanes never share a user, home, checkout, Zig cache or environment. The user and
home are kept for the next run; --remove stops the user's processes and deletes
them and the lane's placed directory.

  python3 tests/ci/fixture_user.py --venv
  python3 tests/ci/fixture_user.py --python

--venv creates or refreshes the caller's own environment at the same
home-relative path; .agents/setup runs it, and tests/ci/prepush.py re-executes
itself in it. --python prints the Python 3.12 those environments are built from
and fails when there is none; .agents/setup installs one when it fails.
"""
import fcntl
import hashlib
import os
from pathlib import Path
import pwd
import re
import shlex
import shutil
import stat
import subprocess
import sys
import tempfile
from typing import NamedTuple

ROOT = Path(__file__).resolve().parents[2]
COMMAND = ".agents/as-fixture-user"
# useradd takes names of at most 32 bytes; "rui-" leaves 28 for the lane.
LANE = re.compile(r"[a-z0-9][a-z0-9-]{0,27}\Z")
PYTHON = "python3.12"
VENV = Path(".local/share/rui/venv-3.12")
STAMP = "rui-requirements.sha256"
REQUIREMENTS = ("tests/ci/requirements.txt", "tests/integration/requirements.txt")
MARKER = ".rui-fixture-user"
CHECKOUT = "rui"
# Everything root places for lanes: tools/ every user reads, lanes/LANE/ only that lane's group reads.
PLACED = Path("/var/lib/rui-fixture")
SOURCE = "source.git"
BUNDLE = "ca-bundle.crt"
# The caller's trust variables, read in this order for the bundle to copy; each
# points at the copy in the run.
TRUST = ("SSL_CERT_FILE", "REQUESTS_CA_BUNDLE", "CURL_CA_BUNDLE", "GIT_SSL_CAINFO", "PIP_CERT",
         "NODE_EXTRA_CA_CERTS")
# Passed through unchanged when the caller sets them: the proxy, which listens
# on loopback for every user, and the terminal and text decoding.
PASSED = ("HTTPS_PROXY", "https_proxy", "NO_PROXY", "no_proxy", "TERM", "LANG", "LC_ALL", "LC_CTYPE")
# Each toolchain's install root, as directories above its binary.
TOOLS = {"zig": 1, "go": 2}
BASE_PATH = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
# What the export holds, in the order root fetches it: REF (named in `export`), then these.
EXPORTED = ("+refs/remotes/origin/main:refs/remotes/origin/main", "+refs/tags/v*:refs/tags/v*")


def say(message):
    print(f"as-fixture-user: {message}", file=sys.stderr, flush=True)


def user_for(lane):
    """The lane's user name; a lane is lowercase letters, digits and dashes."""
    if not LANE.match(lane):
        raise SystemExit(f"{COMMAND}: lane {lane!r} must match {LANE.pattern} (lowercase letters, digits and dashes)")
    return f"rui-{lane}"


def reachable(path):
    """Whether a user with no special rights can search every directory down to `path`."""
    path = Path(path)
    if not path.is_absolute():
        return False
    try:
        return all(os.stat(part).st_mode & stat.S_IXOTH for part in (path, *path.parents))
    except OSError:
        return False


class Install(NamedTuple):
    """An executable a lane runs: its resolved binary and the directory tree it needs."""
    binary: Path
    root: Path


def find_python(search):
    """The first python3.12 on `search` that can build a venv, as an Install; None when there is none.

    The binary is the one the interpreter reports running, so a shim or a venv
    on the search path names the real installation.
    """
    for entry in search.split(os.pathsep):
        candidate = Path(entry) / PYTHON if entry else None
        if candidate is None or not candidate.is_file() or not os.access(candidate, os.X_OK):
            continue
        probe = subprocess.run([str(candidate), "-c", "import ensurepip, sys, venv; print(sys.executable)"],
                               capture_output=True, text=True)
        if probe.returncode == 0 and probe.stdout.strip():
            binary = Path(probe.stdout.strip()).resolve()
            return Install(binary, binary.parents[1])
    return None


def find_tool(tool, search):
    """The caller's `tool` as an Install, or None."""
    found = shutil.which(tool, path=search)
    if found is None:
        return None
    binary = Path(found).resolve()
    return Install(binary, binary.parents[TOOLS[tool] - 1])


def requirement_stamp(texts):
    """What an environment's packages were installed from: the interpreter and the pinned requirements."""
    digest = hashlib.sha256(PYTHON.encode())
    for text in texts:
        digest.update(b"\0" + text.encode())
    return digest.hexdigest()


def venv_home(venv):
    """The directory of the interpreter `venv` was built from, from its pyvenv.cfg; None when unknown."""
    try:
        lines = (venv / "pyvenv.cfg").read_text().splitlines()
    except OSError:
        return None
    for line in lines:
        key, _, value = line.partition("=")
        if key.strip() == "home":
            return Path(value.strip())
    return None


def ensure_venv(venv, interpreter, requirements, run, write):
    """Create or refresh the Python 3.12 environment `venv` from `interpreter`; True when it ran pip.

    `run(argv)` and `write(path, text)` act as the environment's owner. An
    environment built from `interpreter` whose stamp matches `requirements` is
    reused untouched; one with other pins keeps its interpreter and reinstalls
    only the pins; one built from another interpreter is rebuilt.
    """
    want = requirement_stamp([Path(path).read_text() for path in requirements])
    python, stamp = venv / "bin/python", venv / STAMP
    current = python.exists() and venv_home(venv) == Path(interpreter).parent
    if current and stamp.is_file() and stamp.read_text().strip() == want:
        return False
    if not current:
        run([str(interpreter), "-m", "venv", "--clear", str(venv)])
    run([str(python), "-m", "pip", "install", "--quiet", "--disable-pip-version-check",
         *(argument for path in requirements for argument in ("-r", str(path)))])
    write(stamp, want + "\n")
    return True


def pinned_python(home):
    """The environment's interpreter under `home`, or None; warns when its pins differ from this checkout's."""
    venv = home / VENV
    python = venv / "bin/python"
    if not python.exists():
        return None
    stamp = venv / STAMP
    want = requirement_stamp([(ROOT / path).read_text() for path in REQUIREMENTS])
    if not stamp.is_file() or stamp.read_text().strip() != want:
        print(f"{venv} does not match this checkout's requirements; refresh it with "
              "python3 tests/ci/fixture_user.py --venv", file=sys.stderr)
    return python


def reexec_pinned(argv):
    """Replace this process with the same script in the caller's pinned environment, if it exists."""
    python = pinned_python(Path.home())
    if python is not None and Path(sys.prefix).resolve() != python.parent.parent.resolve():
        os.execv(python, [str(python), *argv])


def source_bundle(environ):
    """The caller's CA bundle: the first trust variable that names a file."""
    for name in TRUST:
        if environ.get(name) and Path(environ[name]).is_file():
            return Path(environ[name])
    return None


class Inputs(NamedTuple):
    """Everything a lane needs from root, as root read it from its own state."""
    sha: str
    source: Path  # the repository's common git directory, shared by every worktree
    origin: str  # origin's URL, or "" without one
    bundle: Path | None
    installs: dict  # name -> Install


class Placed(NamedTuple):
    """Every path a lane reads that root provided; nothing else root has reaches the lane."""
    source: Path
    bundle: Path | None
    binaries: dict  # name -> the binary the lane runs


def read_inputs(ref, caller_path, environ, root=ROOT):
    """Root's inputs for a lane at `ref` of the checkout `root`, read before any user exists.

    Refuses a missing commit or Python 3.12.
    """
    git = ["git", "-C", str(root)]
    sha = subprocess.run([*git, "rev-parse", "--verify", "--quiet", f"{ref}^{{commit}}"], capture_output=True,
                         text=True).stdout.strip()
    if not sha:
        raise SystemExit(f"{COMMAND}: {ref!r} names no commit in {root}")
    source = Path(subprocess.check_output([*git, "rev-parse", "--path-format=absolute", "--git-common-dir"],
                                          text=True).strip())
    origin = subprocess.run([*git, "remote", "get-url", "origin"], capture_output=True, text=True).stdout.strip()
    python = find_python(os.pathsep.join(filter(None, (caller_path, BASE_PATH))))
    if python is None:
        raise SystemExit(f"{COMMAND}: no {PYTHON} that can build a venv; .agents/setup installs one")
    installs = {PYTHON: python}
    for tool in TOOLS:
        found = find_tool(tool, caller_path)
        if found is not None:
            installs[tool] = found
    return Inputs(sha, source, origin, source_bundle(environ), installs)


def share(path, gid):
    """Give `path` and everything under it to group `gid`, readable and searchable by it, writable by no one else."""
    for directory, _, files in os.walk(path):
        os.chown(directory, -1, gid)
        os.chmod(directory, 0o750)
        for name in files:
            file = Path(directory) / name
            os.chown(file, -1, gid)
            os.chmod(file, 0o750 if os.stat(file).st_mode & stat.S_IXUSR else 0o640)


def local_fetch(git, repository, *refspecs):
    """`git fetch` of `refspecs` from the local `repository`, which another user may own.

    git trusts that one repository for this fetch only. A local fetch's
    upload-pack drops `git -c` settings, so the trust goes on its command.
    """
    upload_pack = f"git -c safe.directory={shlex.quote(str(repository))} upload-pack"
    return [*git, "fetch", "--quiet", "--no-tags", "--update-shallow", f"--upload-pack={upload_pack}",
            str(repository), *refspecs]


def export(inputs, repository, gid):
    """Fetch the lane's refs from root's repository (and origin's tags) into the bare `repository`."""
    git = ["git", f"--git-dir={repository}"]
    if not repository.is_dir():
        subprocess.run(["git", "init", "--quiet", "--bare", "--template=", str(repository)], check=True)
    subprocess.run(local_fetch(git, inputs.source, f"+{inputs.sha}:refs/heads/fixture"), check=True)
    # Merge bases against origin/main (prepush, select_tests) need it; a repository without one has none.
    for refspec in EXPORTED:
        subprocess.run(local_fetch(git, inputs.source, refspec), stderr=subprocess.DEVNULL)
    tags = subprocess.run([*git, "fetch", "--quiet", "--no-tags", "--update-shallow", inputs.origin, EXPORTED[-1]]
                          ) if inputs.origin else None
    if tags is None or tags.returncode:
        say(f"could not fetch release tags from {inputs.origin or 'an origin remote'}; fixtures that read them "
            "will fail")
    share(repository, gid)


def place_bundle(source, lane_dir, gid):
    """Copy the CA bundle `source` into `lane_dir` for the lane's group; the copy, or None without one."""
    if source is None:
        say("no CA bundle in SSL_CERT_FILE or its peers; the run uses the system trust store")
        return None
    copy, content = lane_dir / BUNDLE, source.read_bytes()
    if not copy.is_file() or copy.read_bytes() != content:
        handle, staging = tempfile.mkstemp(dir=lane_dir)
        with os.fdopen(handle, "wb") as file:
            file.write(content)
        os.chown(staging, -1, gid)
        os.chmod(staging, 0o640)
        os.replace(staging, copy)
    return copy


def place_install(install, tools_dir):
    """The binary the lane runs for `install`: itself when every user reaches it, else a copy in `tools_dir`."""
    if reachable(install.binary):
        return install.binary
    identity = os.stat(install.binary)
    key = hashlib.sha256(f"{install.root}\0{identity.st_dev}:{identity.st_ino}:{identity.st_size}:"
                         f"{identity.st_mtime_ns}".encode()).hexdigest()[:12]
    copy = tools_dir / f"{install.root.name}-{key}"
    if not copy.is_dir():
        staging = Path(tempfile.mkdtemp(dir=tools_dir))
        # Hard links share the files' bytes; another filesystem needs a copy.
        if subprocess.run(["cp", "-al", f"{install.root}/.", str(staging)], stderr=subprocess.DEVNULL).returncode:
            subprocess.run(["cp", "-a", f"{install.root}/.", str(staging)], check=True)
        os.chmod(staging, 0o755)
        try:
            staging.rename(copy)
            say(f"copied {install.root} to {copy} for lanes")
        except OSError:
            # Another lane's run made the same copy first.
            shutil.rmtree(staging)
            if not copy.is_dir():
                raise
    return copy / install.binary.relative_to(install.root)


def public_dir(path):
    """Make `path`, and each parent it lacks, searchable by every user whatever the umask."""
    missing = [part for part in (path, *path.parents) if not part.exists()]
    for part in reversed(missing):
        part.mkdir(exist_ok=True)
        os.chmod(part, 0o755)
    os.chmod(path, 0o755)


def place(inputs, lane_dir, tools_dir, gid):
    """Root's one provisioning step: put each input where group `gid` reads it, and return those paths.

    The git objects and the CA bundle always go to `lane_dir`, which stays the
    caller's and only `gid` reads, so the lane never changes what root reads
    next. An install every user reaches is used in place; any other is copied
    under `tools_dir`, which every user reads.
    """
    public_dir(lane_dir.parent)
    public_dir(tools_dir)
    lane_dir.mkdir(exist_ok=True)
    os.chown(lane_dir, -1, gid)
    os.chmod(lane_dir, 0o750)
    export(inputs, lane_dir / SOURCE, gid)
    bundle = place_bundle(inputs.bundle, lane_dir, gid)
    binaries = {name: place_install(install, tools_dir) for name, install in inputs.installs.items()}
    return Placed(lane_dir / SOURCE, bundle, binaries)


def search_path(venv_bin, placed_dirs, caller_path):
    """The run's PATH: the environment, placed installs, then the caller's directories every user can reach."""
    entries = [str(venv_bin), *map(str, placed_dirs),
               *(entry for entry in (caller_path or BASE_PATH).split(os.pathsep) if reachable(entry))]
    return os.pathsep.join(dict.fromkeys(entries))


def environment(user, home, path, bundle, environ, keep=()):
    """Everything COMMAND sees: `env -i` starts from nothing."""
    fixed = {
        "HOME": str(home), "USER": user, "LOGNAME": user, "SHELL": "/bin/bash", "PATH": path,
        "ZIG_GLOBAL_CACHE_DIR": str(home / ".cache/zig"),
    }
    if bundle is not None:
        fixed.update(dict.fromkeys(TRUST, str(bundle)))
    refused = sorted(set(keep) & set(fixed))
    if refused:
        raise SystemExit(f"{COMMAND}: --keep cannot override the run's own {', '.join(refused)}")
    result = {name: environ[name] for name in (*PASSED, *keep) if name in environ}
    result.update(fixed)
    return result


def env_command(user, env, argv):
    return ["runuser", "-u", user, "--", "env", "-i", *(f"{name}={value}" for name, value in env.items()), *argv]


class Lane:
    """One lane's user, home and checkout, acting as that user, and the directory root places for it."""

    def __init__(self, lane):
        self.lane = lane
        self.user = user_for(lane)
        self.home = Path("/home") / self.user
        self.checkout = self.home / CHECKOUT
        self.venv = self.home / VENV
        self.placed = PLACED / "lanes" / lane
        self.env = {"HOME": str(self.home), "USER": self.user, "LOGNAME": self.user, "PATH": BASE_PATH}

    def run(self, argv, *, check=True, **options):
        return subprocess.run(env_command(self.user, self.env, argv), cwd=self.home, check=check, **options)

    def write(self, path, text):
        self.run(["mkdir", "-p", str(Path(path).parent)])
        self.run(["tee", str(path)], input=text.encode() if isinstance(text, str) else text,
                 stdout=subprocess.DEVNULL)

    def owned(self):
        """Whether the user exists; refuses an account this command did not create."""
        try:
            entry = pwd.getpwnam(self.user)
        except KeyError:
            return False
        marker = self.home / MARKER
        if (entry.pw_uid == 0 or Path(entry.pw_dir) != self.home or not marker.is_file()
                or marker.read_text().strip() != self.lane):
            raise SystemExit(f"{COMMAND}: {self.user} exists but {COMMAND} did not create it for lane {self.lane}")
        return True

    def ensure_user(self):
        if self.owned():
            say(f"reusing {self.user} ({self.home})")
        else:
            subprocess.run(["useradd", "--create-home", "--home-dir", str(self.home), "--shell", "/bin/bash",
                            "--user-group", self.user], check=True)
            os.chmod(self.home, 0o750)
            self.write(self.home / MARKER, self.lane + "\n")
            say(f"created {self.user} ({self.home})")
        return pwd.getpwnam(self.user).pw_gid

    def ensure_checkout(self, source, sha):
        """Check out `sha` from the placed repository `source`, which root owns and the lane's group reads."""
        if not (self.checkout / ".git").is_dir():
            self.run(["git", "init", "--quiet", str(self.checkout)])
        git = ["git", "-C", str(self.checkout)]
        self.run(local_fetch(git, source, "+refs/*:refs/*"))
        self.run([*git, "checkout", "--quiet", "--force", "--detach", sha])
        # Ignored files stay: they are build caches such as .zig-cache, zig-out and zig-pkg.
        self.run([*git, "clean", "-ffdq"])


def lock(lane):
    """Hold the lane for this process's lifetime; COMMAND does not inherit it."""
    handle = open(Path(tempfile.gettempdir()) / f"rui-fixture-user-{lane}.lock", "a")
    try:
        fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        say(f"waiting for lane {lane}'s other run")
        fcntl.flock(handle, fcntl.LOCK_EX)
    return handle


def run(lane, ref, keep, command):
    lane = Lane(lane)
    caller_path = os.environ.get("PATH", BASE_PATH)
    inputs = read_inputs(ref, caller_path, os.environ)
    held = lock(lane.lane)
    placed = place(inputs, lane.placed, PLACED / "tools", lane.ensure_user())
    # The environment carries Python; the toolchains' own directories come before the caller's.
    tools = [binary.parent for name, binary in placed.binaries.items() if name != PYTHON]
    path = search_path(lane.venv / "bin", tools, caller_path)
    network = environment(lane.user, lane.home, path, placed.bundle, os.environ)
    lane.ensure_checkout(placed.source, inputs.sha)
    say(f"{lane.user} at {inputs.sha[:12]} in {lane.checkout}")
    built = ensure_venv(lane.venv, placed.binaries[PYTHON], [lane.checkout / path for path in REQUIREMENTS],
                        lambda argv: subprocess.run(env_command(lane.user, network, argv), cwd=lane.home, check=True),
                        lane.write)
    say(f"{'installed' if built else 'reusing'} {lane.venv}")
    env = environment(lane.user, lane.home, path, placed.bundle, os.environ, keep)
    status = subprocess.run(env_command(lane.user, env, command), cwd=lane.checkout).returncode
    held.close()
    return status


def remove(lane):
    lane = Lane(lane)
    held = lock(lane.lane)
    if not lane.owned():
        raise SystemExit(f"{COMMAND}: {lane.user} does not exist")
    subprocess.run(["pkill", "-KILL", "-u", lane.user])
    subprocess.run(["userdel", "--remove", lane.user], stderr=subprocess.DEVNULL)
    shutil.rmtree(lane.placed, ignore_errors=True)
    if (lane.home.exists() or lane.placed.exists()
            or subprocess.run(["id", lane.user], capture_output=True).returncode == 0):
        raise SystemExit(f"{COMMAND}: could not delete {lane.user}, {lane.home} and {lane.placed}")
    say(f"deleted {lane.user}, {lane.home} and {lane.placed}")
    held.close()
    return 0


USAGE = f"""usage: {COMMAND} LANE [--ref REF] [--keep NAME]... -- COMMAND...
       {COMMAND} --remove LANE
       python3 tests/ci/fixture_user.py --venv
       python3 tests/ci/fixture_user.py --python"""


def parse(argv):
    """(action, lane, ref, keep, command) from the arguments; COMMAND follows `--`."""
    options, command = (argv[:argv.index("--")], argv[argv.index("--") + 1:]) if "--" in argv else (argv, [])
    if options in (["--venv"], ["--python"]) and not command:
        return options[0][2:], None, None, (), []
    if len(options) == 2 and options[0] == "--remove" and not command:
        return "remove", options[1], None, (), []
    lane, ref, keep, rest = None, "HEAD", [], list(options)
    while rest:
        option = rest.pop(0)
        if option in ("--ref", "--keep") and rest:
            value = rest.pop(0)
            if option == "--ref":
                ref = value
            else:
                keep.append(value)
        elif lane is None and not option.startswith("-"):
            lane = option
        else:
            raise SystemExit(USAGE)
    if lane is None or not command:
        raise SystemExit(USAGE)
    user_for(lane)
    return "run", lane, ref, tuple(keep), command


def main(argv):
    action, lane, ref, keep, command = parse(argv)
    if action in ("python", "venv"):
        python = find_python(os.pathsep.join(filter(None, (os.environ.get("PATH"), BASE_PATH))))
        if python is None:
            print(f"No {PYTHON} that can build a venv; .agents/setup installs one.", file=sys.stderr)
            return 1
        if action == "python":
            print(python.binary)
            return 0
        home = Path.home()
        built = ensure_venv(home / VENV, python.binary, [ROOT / path for path in REQUIREMENTS],
                            lambda argv: subprocess.run(argv, check=True), lambda path, text: path.write_text(text))
        print(f"{'Installed' if built else 'Reusing'} {home / VENV}.")
        return 0
    if os.geteuid() != 0:
        raise SystemExit(f"{COMMAND} creates users, so it runs as root; as an ordinary user, run COMMAND directly.")
    try:
        return remove(lane) if action == "remove" else run(lane, ref, keep, command)
    except subprocess.CalledProcessError as error:
        # Name the command, not the environment env_command gives it.
        words = error.cmd[error.cmd.index("-i") + 1:] if "-i" in error.cmd else error.cmd
        while words and "=" in words[0]:
            words = words[1:]
        raise SystemExit(f"{COMMAND}: exit {error.returncode} from {' '.join(words)}")


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
