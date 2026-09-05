"""Native macOS synthetic capture sweep; invokes no LLMs or OnePage stores."""
import argparse
import json
import pathlib
import platform
import re
import statistics
import subprocess
import tarfile
import tempfile

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parent.parent


def run(*args):
    return subprocess.check_output([str(a) for a in args], text=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--repeats", type=int, default=5)
    parser.add_argument("--output", type=pathlib.Path, default=HERE / "single-connection-results.json")
    args = parser.parse_args()
    zon = (ROOT / "build.zig.zon").read_text()
    sqlite_hash = re.search(r'\.sqlite = .*?\.hash = "([^"]+)"', zon, re.S)[1]
    zig_env = run("zig", "env")
    cache = pathlib.Path(re.search(r'\.global_cache_dir = "([^"]+)"', zig_env)[1])
    archive = cache / "p" / (sqlite_hash + ".tar.gz")
    build = (ROOT / "build.zig").read_text()
    flags = [f"-D{k}={v}" for k, v in re.findall(r'addCMacro\("(SQLITE_[^"]+)", "([^"]+)"\)', build)]
    output = {"platform": platform.platform(), "compiler": run("cc", "--version"),
              "hardware_model": run("sysctl", "-n", "hw.model").strip(),
              "physical_memory_bytes": int(run("sysctl", "-n", "hw.memsize")),
              "sqlite_package_hash": sqlite_hash, "compile_flags": flags,
              "git_head": run("git", "-C", ROOT, "rev-parse", "HEAD").strip(),
              "repeats": args.repeats, "observations": []}
    with tempfile.TemporaryDirectory(prefix="onepage-single-capture-") as tmp:
        temp = pathlib.Path(tmp)
        with tarfile.open(archive) as source:
            for name in ("sqlite3.c", "sqlite3.h"):
                member = next(m for m in source.getmembers() if pathlib.PurePosixPath(m.name).name == name)
                (temp / name).write_bytes(source.extractfile(member).read())
        binary = temp / "capture"
        subprocess.run(["cc", "-O2", "-std=c99", "-fno-strict-aliasing", *flags,
                        "-I", str(temp), str(HERE / "single_connection.c"),
                        str(temp / "sqlite3.c"), "-o", str(binary)], check=True)
        cases = [(100, 128), (1000, 128), (10000, 128), (100000, 128),
                 (1000000, 128), (10000, 1024), (100000, 1024)]
        for rows, width in cases:
            db = temp / f"fixture-{rows}-{width}.db"
            run(binary, db, "seed", rows, width, 0)
            # Rotate access strategy order. Each capture uses a fresh process/SQLite cache.
            # OS filesystem caches are not purged; this is not a cold-disk benchmark.
            for repeat in range(args.repeats):
                modes = [0, 100, 1]
                modes = modes[repeat % 3:] + modes[:repeat % 3]
                for batch in modes:
                    obs = json.loads(run(binary, db, "capture", rows, width, batch))
                    obs.update(repeat=repeat, database_bytes=db.stat().st_size)
                    output["observations"].append(obs)
            db.unlink()
            print(f"Completed {rows:,} records / {width} binding bytes", flush=True)
        output["summaries"] = []
        for rows, width in cases:
            for batch in (0, 100, 1):
                subset = [o for o in output["observations"]
                          if (o["rows"], o["binding_bytes"], o["batch"]) == (rows, width, batch)]
                times = [o["capture_ms"] for o in subset]
                output["summaries"].append({"rows": rows, "binding_bytes": width, "batch": batch,
                    "report_bytes": subset[0]["report_bytes"],
                    "median_ms": statistics.median(times), "min_ms": min(times), "max_ms": max(times),
                    "max_sqlite_heap_peak": max(o["sqlite_heap_peak"] for o in subset),
                    "max_sampled_physical_increment": max(o["physical_peak_sampled"] - o["physical_baseline"] for o in subset)})
    args.output.write_text(json.dumps(output, indent=2) + "\n")
    print(json.dumps(output["summaries"], indent=2))


if __name__ == "__main__":
    main()
