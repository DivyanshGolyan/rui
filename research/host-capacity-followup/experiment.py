"""Run the follow-up in disposable build storage; no installation."""
import pathlib, subprocess, sys, tempfile
p=pathlib.Path(__file__).resolve().parent
with tempfile.TemporaryDirectory(prefix='onepage-followup-curl-PROTOTYPE-') as tmp:
    subprocess.run([sys.executable,str(p.parent/'host-capacity-scaling/build_probe_curl.py'),tmp],check=True)
    subprocess.run([sys.executable,str(p/'run.py'),'--curl-build',str(pathlib.Path(tmp)/'curl-8.7.1')],check=True)
    subprocess.run([sys.executable,str(p/'run.py'),'--refined','--curl-build',str(pathlib.Path(tmp)/'curl-8.7.1')],check=True)
