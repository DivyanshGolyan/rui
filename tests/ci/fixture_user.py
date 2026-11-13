#!/usr/bin/env python3
"""Run a command as a lane's own non-root fixture user; own the pinned Python 3.12 environment.

Fixtures refuse root (VERIFICATION.md, Canonical gates), and cloud containers
run as root. `.agents/as-fixture-user` runs this module as root:

  .agents/as-fixture-user LANE [--ref REF] [--keep NAME]... -- COMMAND...
  .agents/as-fixture-user --remove LANE

The first run for LANE creates the user `rui-LANE` with the home /home/rui-LANE.
Every run then, under that lane's lock:
  - checks out REF (default HEAD) of this checkout's repository at ~/rui as
    that user, fetching it with origin/main from this repository and the
    release tags from origin, and removes untracked files that are not ignored
    (ignored build caches stay);
  - copies the caller's CA bundle to ~/.config/rui-fixture/ca-bundle.crt;
  - makes the caller's Zig and Go reachable when they sit behind an
    unreadable directory such as /root, through a hard-linked copy under
    /usr/local/lib/rui-fixture-tools;
  - keeps the Python 3.12 environment at ~/.local/share/rui/venv-3.12 current
    with tests/ci/requirements.txt and tests/integration/requirements.txt at
    REF, rebuilding nothing whose pins are unchanged;
  - runs COMMAND in ~/rui as that user under `env -i`, with only the
    variables `environment` names, and exits with its status.
Lanes never share a user, home, checkout, Zig cache or environment. The user and
home are kept for the next run; --remove stops the user's processes and deletes both.

  python3 tests/ci/fixture_user.py --venv
  python3 tests/ci/fixture_user.py --python

--venv creates or refreshes the caller's own environment at the same
home-relative path; .agents/setup runs it, and tests/ci/prepush.py re-executes
itself in it. --python prints the Python 3.12 those environments are built from
and fails when there is none; as root it names only one a fixture user can run,
and .agents/setup installs one when it fails.
"""
import fcntl
import hashlib
import os
from pathlib import Path
import pwd
import re
import shutil
import stat
import subprocess
import sys
import tempfile

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
CA_COPY = Path(".config/rui-fixture/ca-bundle.crt")
# The caller's trust variables, read in this order for the bundle to copy; each
# points at the copy in the run.
TRUST = ("SSL_CERT_FILE", "REQUESTS_CA_BUNDLE", "CURL_CA_BUNDLE", "GIT_SSL_CAINFO", "PIP_CERT",
         "NODE_EXTRA_CA_CERTS")
# Passed through unchanged when the caller sets them: the proxy, which listens
# on loopback for every user, and the terminal and text decoding.
PASSED = ("HTTPS_PROXY", "https_proxy", "NO_PROXY", "no_proxy", "TERM", "LANG", "LC_ALL", "LC_CTYPE")
# Each toolchain's install root, as directories above its binary.
TOOLS = {"zig": 1, "go": 2}
TOOL_MIRROR = Path("/usr/local/lib/rui-fixture-tools")
BASE_PATH = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"


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


def usable_python(search, public):
    """The first python3.12 on `search` that can build a venv, resolved; None when there is none.

    With `public`, only an interpreter every user can run counts: a lane's user
    cannot follow a name on root's PATH into /root (a pyenv shim, uv's default
    install), even through a link in a directory it can search.
    """
    for entry in search.split(os.pathsep):
        candidate = Path(entry) / PYTHON if entry else None
        if candidate is None or not candidate.is_file() or not os.access(candidate, os.X_OK):
            continue
        interpreter = candidate.resolve()
        if public and not reachable(interpreter):
            continue
        if subprocess.run([str(interpreter), "-c", "import ensurepip, venv"], capture_output=True).returncode == 0:
            return interpreter
    return None


def fixture_python(caller_path, system_path=BASE_PATH):
    """The Python 3.12 a lane's environment is built from: the caller's first one every user can run."""
    python = usable_python(os.pathsep.join(filter(None, (caller_path, system_path))), public=True)
    if python is None:
        raise SystemExit(f"{COMMAND}: no {PYTHON} that a fixture user can run; .agents/setup installs one "
                         "under /usr/local")
    return python


def requirement_stamp(texts):
    """What an environment's packages were installed from: the interpreter and the pinned requirements."""
    digest = hashlib.sha256(PYTHON.encode())
    for text in texts:
        digest.update(b"\0" + text.encode())
    return digest.hexdigest()


def ensure_venv(venv, interpreter, requirements, run, write):
    """Create or refresh the Python 3.12 environment `venv` from `interpreter`; True when it ran pip.

    `run(argv)` and `write(path, text)` act as the environment's owner. An
    environment whose stamp matches `requirements` is reused untouched; one
    with other pins keeps its interpreter and reinstalls only the pins.
    """
    want = requirement_stamp([Path(path).read_text() for path in requirements])
    python, stamp = venv / "bin/python", venv / STAMP
    if python.exists() and stamp.is_file() and stamp.read_text().strip() == want:
        return False
    if not python.exists():
        run([str(interpreter), "-m", "venv", str(venv)])
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


def search_path(venv_bin, mirrored, caller_path):
    """The run's PATH: the environment, mirrored toolchains, then the caller's directories every user can reach."""
    entries = [str(venv_bin), *map(str, mirrored),
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
    """One lane's user, home and checkout, acting as that user."""

    def __init__(self, lane):
        self.lane = lane
        self.user = user_for(lane)
        self.home = Path("/home") / self.user
        self.checkout = self.home / CHECKOUT
        self.venv = self.home / VENV
        self.bundle = self.home / CA_COPY
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
            return
        subprocess.run(["useradd", "--create-home", "--home-dir", str(self.home), "--shell", "/bin/bash",
                        "--user-group", self.user], check=True)
        os.chmod(self.home, 0o750)
        self.write(self.home / MARKER, self.lane + "\n")
        say(f"created {self.user} ({self.home})")

    def ensure_bundle(self, environ):
        source = source_bundle(environ)
        if source is None:
            say("no CA bundle in SSL_CERT_FILE or its peers; the run uses the system trust store")
            return None
        content = source.read_bytes()
        if not self.bundle.is_file() or self.bundle.read_bytes() != content:
            self.write(self.bundle, content)
        return self.bundle

    def ensure_checkout(self, sha, network):
        if not (self.checkout / ".git").is_dir():
            self.run(["git", "init", "--quiet", str(self.checkout)])
        git = ["git", "-C", str(self.checkout)]
        # The repository every worktree shares: git upload-pack refuses a linked worktree's path
        # owned by another user even when safe.directory names it.
        source = subprocess.check_output(["git", "-C", str(ROOT), "rev-parse", "--path-format=absolute",
                                          "--git-common-dir"], text=True).strip()
        # Only this repository, never '*': git refuses to read another user's repository without it.
        trusted = self.run(["git", "config", "--global", "--get-all", "safe.directory"], check=False,
                           capture_output=True, text=True).stdout.split("\n")
        if source not in trusted:
            self.run(["git", "config", "--global", "--add", "safe.directory", source])
        self.run([*git, "fetch", "--quiet", "--no-tags", "--update-shallow", source, f"+{sha}:refs/heads/fixture"])
        # Merge bases against origin/main (prepush, select_tests) need it; a repository without one skips it.
        self.run([*git, "fetch", "--quiet", "--no-tags", "--update-shallow", source,
                  "+refs/remotes/origin/main:refs/remotes/origin/main"], check=False, stderr=subprocess.DEVNULL)
        self.run([*git, "checkout", "--quiet", "--force", "--detach", sha])
        # Ignored files stay: they are build caches such as .zig-cache, zig-out and zig-pkg.
        self.run([*git, "clean", "-ffdq"])
        origin = subprocess.run(["git", "-C", str(ROOT), "remote", "get-url", "origin"], capture_output=True,
                                text=True).stdout.strip()
        tags = subprocess.run(env_command(self.user, network, [*git, "fetch", "--quiet", "--no-tags", "--force",
                                                                origin, "+refs/tags/v*:refs/tags/v*"]),
                              cwd=self.home) if origin else None
        if tags is None or tags.returncode:
            say(f"could not fetch release tags from {origin or 'an origin remote'}; fixtures that read them will fail")

    def ensure_tools(self, caller_path):
        mirrored = []
        for tool, levels in TOOLS.items():
            found = shutil.which(tool, path=caller_path)
            if found is None:
                continue
            binary = Path(found).resolve()
            if reachable(binary):
                continue
            install = binary.parents[levels - 1]
            key = hashlib.sha256(str(install).encode()).hexdigest()[:8]
            mirror = TOOL_MIRROR / f"{install.name}-{key}"
            if not mirror.is_dir():
                TOOL_MIRROR.mkdir(parents=True, exist_ok=True)
                os.chmod(TOOL_MIRROR, 0o755)
                staging = Path(tempfile.mkdtemp(dir=TOOL_MIRROR))
                # Hard links share the files' bytes; another filesystem needs a copy.
                if subprocess.run(["cp", "-al", f"{install}/.", str(staging)]).returncode:
                    subprocess.run(["cp", "-a", f"{install}/.", str(staging)], check=True)
                os.chmod(staging, 0o755)
                try:
                    staging.rename(mirror)
                    say(f"made {tool} reachable at {mirror}")
                except OSError:
                    # Another lane's run made the same mirror first.
                    shutil.rmtree(staging)
                    if not mirror.is_dir():
                        raise
            mirrored.append(mirror / binary.relative_to(install).parent)
        return mirrored


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
    interpreter = fixture_python(caller_path)
    sha = subprocess.run(["git", "-C", str(ROOT), "rev-parse", "--verify", "--quiet", f"{ref}^{{commit}}"],
                         capture_output=True, text=True).stdout.strip()
    if not sha:
        raise SystemExit(f"{COMMAND}: {ref!r} names no commit in {ROOT}")
    held = lock(lane.lane)
    lane.ensure_user()
    bundle = lane.ensure_bundle(os.environ)
    path = search_path(lane.venv / "bin", lane.ensure_tools(caller_path), caller_path)
    network = environment(lane.user, lane.home, path, bundle, os.environ)
    lane.ensure_checkout(sha, network)
    say(f"{lane.user} at {sha[:12]} in {lane.checkout}")
    built = ensure_venv(lane.venv, interpreter, [lane.checkout / path for path in REQUIREMENTS],
                        lambda argv: subprocess.run(env_command(lane.user, network, argv), cwd=lane.home, check=True),
                        lane.write)
    say(f"{'installed' if built else 'reusing'} {lane.venv}")
    env = environment(lane.user, lane.home, path, bundle, os.environ, keep)
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
    if lane.home.exists() or subprocess.run(["id", lane.user], capture_output=True).returncode == 0:
        raise SystemExit(f"{COMMAND}: could not delete {lane.user} and {lane.home}")
    say(f"deleted {lane.user} and {lane.home}")
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
    if action == "python":
        # .agents/setup's question: root's interpreter must serve fixture users too.
        search = os.pathsep.join(filter(None, (os.environ.get("PATH"), BASE_PATH)))
        python = usable_python(search, public=os.geteuid() == 0)
        if python is None:
            print(f"No {PYTHON} that can build a venv{' for a fixture user' if os.geteuid() == 0 else ''}.",
                  file=sys.stderr)
            return 1
        print(python)
        return 0
    if action == "venv":
        home = Path.home()
        interpreter = usable_python(os.environ.get("PATH", BASE_PATH), public=False)
        if interpreter is None:
            raise SystemExit(f"No {PYTHON} that can build a venv; .agents/setup installs one.")
        built = ensure_venv(home / VENV, interpreter, [ROOT / path for path in REQUIREMENTS],
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
