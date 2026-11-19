#!/usr/bin/env python3
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
sys.path.insert(0, str(ROOT / "tests/integration"))
import network_variables  # noqa: E402
COMMAND = ".agents/as-fixture-user"
# useradd takes names of at most 32 bytes; "rui-" leaves 28 for the lane.
LANE = re.compile(r"[a-z0-9][a-z0-9-]{0,27}\Z")
PYTHON = "python3.12"
VENV = Path(".local/share/rui/venv-3.12")
STAMP = "rui-requirements.sha256"
REQUIREMENTS = ("tests/ci/requirements.txt", "tests/integration/requirements.txt")
MARKER = ".rui-fixture-user"
CHECKOUT = "rui"
PLACED = Path("/var/lib/rui-fixture")
HOMES = Path("/home")
SOURCE = "source.git"
TRUST_COPIES = "trust"
# Tools' own trust variables. Each means something different to its tool (node's
# adds to its store, pip's replaces it), so each is moved as the caller set it.
TOOL_TRUST = ("REQUESTS_CA_BUNDLE", "CURL_CA_BUNDLE", "GIT_SSL_CAINFO", "PIP_CERT", "NODE_EXTRA_CA_CERTS")
# OpenSSL reads its certificate directory variable as a list of directories.
TRUST_LISTS = ("SSL_CERT_DIR",)
PASSED = (*network_variables.PROXY, "TERM", "LANG", "LC_ALL", "LC_CTYPE")
TOOLS = {"zig": (("env",), re.compile(r'\blib_dir"?\s*[:=]\s*"([^"]+)"'),
                 re.compile(r'\bzig_exe"?\s*[:=]\s*"([^"]+)"')),
         "go": (("env", "GOROOT"), re.compile(r"^(/.*)$", re.M), Path("bin/go"))}
BASE_PATH = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
SYSTEM_PLACES = (Path("/usr"), *(Path(entry) for entry in BASE_PATH.split(os.pathsep)))
EXPORTED = ("+refs/remotes/origin/main:refs/remotes/origin/main", "+refs/tags/v*:refs/tags/v*")


def say(message):
    print(f"as-fixture-user: {message}", file=sys.stderr, flush=True)


def user_for(lane):
    if not LANE.match(lane):
        raise SystemExit(f"{COMMAND}: lane {lane!r} must match {LANE.pattern} (lowercase letters, digits and dashes)")
    return f"rui-{lane}"


class Install(NamedTuple):
    binary: Path
    trees: tuple

    @property
    def parts(self):
        paths = (self.binary, *self.trees)
        return tuple(sorted({path for path in paths
                             if not any(path != other and path.is_relative_to(other) for other in paths)}))

    @property
    def root(self):
        return Path(os.path.commonpath([self.binary.parent, *self.trees]))


def find_python(search):
    for entry in search.split(os.pathsep):
        candidate = Path(entry) / PYTHON if entry else None
        if candidate is None or not candidate.is_file() or not os.access(candidate, os.X_OK):
            continue
        probe = subprocess.run([str(candidate), "-c",
                                "import ensurepip, sys, venv; print(sys.executable); print(sys.base_prefix)"],
                               capture_output=True, text=True)
        reported = probe.stdout.splitlines()
        if probe.returncode == 0 and len(reported) == 2 and all(reported):
            return Install(Path(reported[0]).resolve(), (Path(reported[1]).resolve(),))
    return None


def find_tool(tool, search):
    found = shutil.which(tool, path=search)
    if found is None:
        return None
    arguments, tree, binary = TOOLS[tool]
    report = subprocess.run([found, *arguments], capture_output=True, text=True)
    answer = report.stdout if report.returncode == 0 else ""
    trees = tuple(Path(match).resolve() for match in tree.findall(answer))
    if isinstance(binary, Path):
        binaries = [trees[0] / binary] if trees else []
    else:
        binaries = [Path(match) for match in binary.findall(answer)]
    if not trees or len(binaries) != 1 or not os.access(binaries[0], os.X_OK):
        raise SystemExit(f"{COMMAND}: {found} {' '.join(arguments)} reported no binary and tree to place")
    return Install(binaries[0].resolve(), trees)


def requirement_stamp(texts):
    digest = hashlib.sha256(PYTHON.encode())
    for text in texts:
        digest.update(b"\0" + text.encode())
    return digest.hexdigest()


def venv_home(venv):
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
    python = pinned_python(Path.home())
    if python is not None and Path(sys.prefix).resolve() != python.parent.parent.resolve():
        os.execv(python, [str(python), *argv])


def trust_sources(environ):
    trust = {}
    for name in (*network_variables.TRUST, *TOOL_TRUST):
        value = environ.get(name, "")
        entries = [Path(entry) for entry in value.split(os.pathsep) if entry] if name in TRUST_LISTS else [
            Path(value)] if value else []
        for missing in (entry for entry in entries if not entry.exists()):
            say(f"{name} names {missing}, which does not exist; the run leaves it out")
        present = tuple(entry for entry in entries if entry.exists())
        if present:
            trust[name] = present
    if not trust:
        say("no CA bundle or certificate directory in the caller's trust variables; the run uses the system "
            "trust store")
    return trust


class Inputs(NamedTuple):
    sha: str
    source: Path
    origin: str
    trust: dict
    installs: dict


class Placed(NamedTuple):
    source: Path
    trust: dict
    binaries: dict


def read_inputs(ref, caller_path, environ, root=ROOT):
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
    return Inputs(sha, source, origin, trust_sources(environ), installs)


def share(path, gid):
    for directory, _, files in os.walk(path):
        os.chown(directory, -1, gid)
        os.chmod(directory, 0o750)
        for name in files:
            file = Path(directory) / name
            os.chown(file, -1, gid)
            os.chmod(file, 0o750 if os.stat(file).st_mode & stat.S_IXUSR else 0o640)


def local_fetch(git, repository, *refspecs):
    upload_pack = f"git -c safe.directory={shlex.quote(str(repository))} upload-pack"
    return [*git, "fetch", "--quiet", "--no-tags", "--update-shallow", f"--upload-pack={upload_pack}",
            str(repository), *refspecs]


def export(inputs, repository, gid):
    git = ["git", "-c", "maintenance.auto=false", "-c", "gc.auto=0", f"--git-dir={repository}"]
    if not repository.is_dir():
        subprocess.run(["git", "init", "--quiet", "--bare", "--template=", str(repository)], check=True)
    subprocess.run(local_fetch(git, inputs.source, f"+{inputs.sha}:refs/heads/fixture"), check=True)
    for refspec in EXPORTED:
        subprocess.run(local_fetch(git, inputs.source, refspec), stderr=subprocess.DEVNULL)
    tags = subprocess.run([*git, "fetch", "--quiet", "--no-tags", "--update-shallow", inputs.origin, EXPORTED[-1]]
                          ) if inputs.origin else None
    if tags is None or tags.returncode:
        say(f"could not fetch release tags from {inputs.origin or 'an origin remote'}; fixtures that read them "
            "will fail")
    share(repository, gid)


def contents(path):
    if path.is_dir():
        return {entry.name: entry.read_bytes() for entry in sorted(path.iterdir()) if entry.is_file()}
    return path.read_bytes() if path.is_file() else None


def place_trust(trust, trust_dir, gid):
    trust_dir.mkdir(exist_ok=True)
    copies = {}
    for name, sources in trust.items():
        for index, source in enumerate(sources):
            if source in copies:
                continue
            copies[source] = trust_dir / f"{name}.{index}"
            wanted = contents(source)
            if contents(copies[source]) == wanted:
                continue
            staging = Path(tempfile.mkdtemp(dir=trust_dir))
            copy = staging / "copy"
            if isinstance(wanted, dict):
                copy.mkdir()
                for entry, data in wanted.items():
                    (copy / entry).write_bytes(data)
            else:
                copy.write_bytes(wanted)
            share(staging, gid)
            if copies[source].exists() or copies[source].is_symlink():
                copies[source].rename(staging / "old")
            copy.rename(copies[source])
            shutil.rmtree(staging)
    for stale in set(trust_dir.iterdir()) - set(copies.values()):
        if stale.is_dir() and not stale.is_symlink():
            shutil.rmtree(stale)
        else:
            stale.unlink()
    share(trust_dir, gid)
    return {name: tuple(copies[source] for source in sources) for name, sources in trust.items()}


def place_install(install, tools_dir):
    if any(install.binary.is_relative_to(place) for place in SYSTEM_PLACES):
        return install.binary
    identity = os.stat(install.binary)
    parts = "\0".join(map(str, install.parts))
    key = hashlib.sha256(f"{parts}\0{identity.st_dev}:{identity.st_ino}:{identity.st_size}:"
                         f"{identity.st_mtime_ns}\0readable copy".encode()).hexdigest()[:12]
    copy = tools_dir / f"{install.root.name}-{key}"
    if not copy.is_dir():
        staging = Path(tempfile.mkdtemp(dir=tools_dir))
        for part in install.parts:
            target = staging / part.relative_to(install.root)
            target.parent.mkdir(parents=True, exist_ok=True)
            if part.is_dir():
                target.mkdir(exist_ok=True)
                subprocess.run(["cp", "-a", f"{part}/.", str(target)], check=True)
            else:
                subprocess.run(["cp", "-a", str(part), str(target)], check=True)
        subprocess.run(["chmod", "-R", "a+rX", str(staging)], check=True)
        try:
            staging.rename(copy)
            say(f"copied {install.root} to {copy} for lanes")
        except OSError:
            shutil.rmtree(staging)
            if not copy.is_dir():
                raise
    return copy / install.binary.relative_to(install.root)


def public_dir(path):
    missing = [part for part in (path, *path.parents) if not part.exists()]
    for part in reversed(missing):
        part.mkdir(exist_ok=True)
        os.chmod(part, 0o755)
    os.chmod(path, 0o755)


def place(inputs, lane_dir, tools_dir, gid):
    public_dir(lane_dir.parent)
    public_dir(tools_dir)
    lane_dir.mkdir(exist_ok=True)
    os.chown(lane_dir, -1, gid)
    os.chmod(lane_dir, 0o750)
    export(inputs, lane_dir / SOURCE, gid)
    trust = place_trust(inputs.trust, lane_dir / TRUST_COPIES, gid)
    binaries = {name: place_install(install, tools_dir) for name, install in inputs.installs.items()}
    return Placed(lane_dir / SOURCE, trust, binaries)


def search_path(venv_bin, placed_dirs, caller_path):
    entries = [str(venv_bin), *map(str, placed_dirs), *(caller_path or BASE_PATH).split(os.pathsep)]
    return os.pathsep.join(dict.fromkeys(entry for entry in entries if entry))


def environment(user, home, path, trust, environ, keep=()):
    fixed = {
        "HOME": str(home), "USER": user, "LOGNAME": user, "SHELL": "/bin/bash", "PATH": path,
        "ZIG_GLOBAL_CACHE_DIR": str(home / ".cache/zig"),
        **{name: os.pathsep.join(map(str, copies)) for name, copies in trust.items()},
    }
    withheld = (*network_variables.TRUST, *TOOL_TRUST)
    refused = sorted(set(keep) & {*fixed, *withheld})
    if refused:
        raise SystemExit(f"{COMMAND}: --keep cannot override the run's own {', '.join(refused)}")
    result = {name: environ[name] for name in (*PASSED, *keep) if name in environ}
    result.update(fixed)
    return result


def as_lane(user, env, argv, **options):
    return subprocess.run(argv, env=env, user=user, group=user, extra_groups=[], **options)


class Lane:

    def __init__(self, lane):
        self.lane = lane
        self.user = user_for(lane)
        self.home = HOMES / self.user
        self.checkout = self.home / CHECKOUT
        self.venv = self.home / VENV
        self.placed = PLACED / "lanes" / lane
        self.env = {"HOME": str(self.home), "USER": self.user, "LOGNAME": self.user, "PATH": BASE_PATH}

    def run(self, argv, *, check=True, **options):
        return as_lane(self.user, self.env, argv, cwd=self.home, check=check, **options)

    def write(self, path, text):
        self.run(["mkdir", "-p", str(Path(path).parent)])
        self.run(["tee", str(path)], input=text.encode() if isinstance(text, str) else text,
                 stdout=subprocess.DEVNULL)

    def owned(self):
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

    def seed_packages(self, caller_cache):
        """Copy the caller's fetched Zig packages the lane lacks; packages are named by their hash."""
        source = Path(caller_cache) / "p"
        if not source.is_dir():
            return 0
        target = self.home / ".cache/zig/p"
        self.run(["mkdir", "-p", str(target)])
        missing = [entry for entry in sorted(source.iterdir()) if not (target / entry.name).exists()]
        for entry in missing:
            if entry.is_dir() and not entry.is_symlink():
                shutil.copytree(entry, target / entry.name, symlinks=True)
            else:
                shutil.copy2(entry, target / entry.name, follow_symlinks=False)
            subprocess.run(["chown", "-R", f"{self.user}:{self.user}", str(target / entry.name)], check=True)
        return len(missing)

    def ensure_checkout(self, source, sha):
        if not (self.checkout / ".git").is_dir():
            self.run(["git", "init", "--quiet", str(self.checkout)])
        git = ["git", "-C", str(self.checkout)]
        self.run(local_fetch(git, source, "+refs/*:refs/*"))
        self.run([*git, "checkout", "--quiet", "--force", "--detach", sha])
        self.run([*git, "clean", "-ffdq"])


def lock(lane):
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
    tools = [binary.parent for name, binary in placed.binaries.items() if name != PYTHON]
    path = search_path(lane.venv / "bin", tools, caller_path)
    network = environment(lane.user, lane.home, path, placed.trust, os.environ)
    lane.ensure_checkout(placed.source, inputs.sha)
    caller_cache = os.environ.get("ZIG_GLOBAL_CACHE_DIR") or str(Path.home() / ".cache/zig")
    seeded = lane.seed_packages(caller_cache)
    if seeded:
        say(f"copied {seeded} Zig package(s) from {caller_cache}")
    say(f"{lane.user} at {inputs.sha[:12]} in {lane.checkout}")
    built = ensure_venv(lane.venv, placed.binaries[PYTHON], [lane.checkout / path for path in REQUIREMENTS],
                        lambda argv: as_lane(lane.user, network, argv, cwd=lane.home, check=True),
                        lane.write)
    say(f"{'installed' if built else 'reusing'} {lane.venv}")
    env = environment(lane.user, lane.home, path, placed.trust, os.environ, keep)
    status = as_lane(lane.user, env, command, cwd=lane.checkout).returncode
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
        raise SystemExit(f"{COMMAND}: exit {error.returncode} from {' '.join(map(str, error.cmd))}")


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
