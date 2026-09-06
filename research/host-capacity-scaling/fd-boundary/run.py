"""Tiny local socketpair experiment; no network transfers or high load."""
import pathlib, subprocess, tempfile, platform, datetime
p=pathlib.Path(__file__).resolve().parent
with tempfile.TemporaryDirectory(prefix="onepage-fd-boundary-") as d:
    binary=pathlib.Path(d)/"probe"
    subprocess.run(["clang","-O2","-std=c11","-Wall","-Wextra","-Werror",str(p/"probe.c"),"-o",str(binary),"-lcurl"],check=True)
    result=subprocess.run([str(binary)],check=True,capture_output=True,text=True)
    output=f"Date: {datetime.datetime.now().astimezone().isoformat()}\nPlatform: {platform.platform()}\n"+result.stdout
    (p/"results.txt").write_text(output)
    print(output,end="")
