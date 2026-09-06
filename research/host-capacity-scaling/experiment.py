"""One-command full experiment; downloads/builds curl in disposable storage."""
import pathlib, subprocess, sys, tempfile
p=pathlib.Path(__file__).resolve().parent
with tempfile.TemporaryDirectory(prefix='onepage-capacity-curl-PROTOTYPE-') as tmp:
    subprocess.run([sys.executable,str(p/'build_probe_curl.py'),tmp],check=True)
    subprocess.run([sys.executable,str(p/'run.py'),'--curl-build',str(pathlib.Path(tmp)/'curl-8.7.1')],check=True)
