"""Throwaway probes: build against Rui's cached, pinned SQLite amalgamation."""
import argparse
import json
from pathlib import Path
import platform
import re
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def output(*args):
    return subprocess.check_output(list(map(str, args)), text=True).strip()


def metadata():
    return {
        "platform": platform.platform(),
        "hardware": output("sysctl", "-n", "hw.model"),
        "memory_bytes": int(output("sysctl", "-n", "hw.memsize")),
        "compiler": output("cc", "--version"),
        "baseline": output("git", "-C", ROOT, "rev-parse", "HEAD"),
    }


def build(source, destination, sanitize=False):
    zon = (ROOT / "build.zig.zon").read_text()
    package = re.search(r'\.sqlite = .*?\.hash = "([^"]+)"', zon, re.S)[1]
    cache = Path(re.search(r'\.global_cache_dir = "([^"]+)"', output("zig", "env"))[1])
    flags = [f"-D{k}={v}" for k, v in re.findall(
        r'addCMacro\("(SQLITE_[^"]+)", "([^"]+)"\)', (ROOT / "build.zig").read_text())]
    with tempfile.TemporaryDirectory(prefix="rui-probe-build-") as tmp:
        tmp = Path(tmp)
        with tarfile.open(cache / "p" / (package + ".tar.gz")) as archive:
            for filename in ("sqlite3.c", "sqlite3.h"):
                member = next(m for m in archive.getmembers() if Path(m.name).name == filename)
                (tmp / filename).write_bytes(archive.extractfile(member).read())
        command = ["cc", "-O2", "-g", "-std=c11", "-fno-strict-aliasing", "-pthread"]
        if sanitize:
            command += ["-fsanitize=address,undefined", "-fno-omit-frame-pointer"]
        command += flags + ["-I", str(tmp), str(source), str(tmp / "sqlite3.c"), "-o", str(destination)]
        subprocess.run(command, check=True)
    return {"sqlite_package": package, "sqlite_flags": flags, "sanitized": sanitize}


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    parser.add_argument("--sanitize", action="store_true")
    args = parser.parse_args()
    print(json.dumps(build(args.source, args.destination, args.sanitize)))
