"""The one way CI scripts run git for its output."""
import subprocess


def git(*args, cwd=None, strip=True, stderr=subprocess.PIPE, env=None):
    """Git's standard output for `args`, run in `cwd` with environment `env`
    (the process's own when None); stripped unless `strip` is false. A failure
    raises CalledProcessError. Its standard error is captured, or with
    `stderr=None` passes through to this process's."""
    output = subprocess.run(["git", *args], cwd=cwd, env=env, check=True, stdout=subprocess.PIPE, stderr=stderr, text=True).stdout
    return output.strip() if strip else output
