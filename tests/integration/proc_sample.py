"""One Linux /proc sample of a process's memory and descriptors, shared by the
saved-request and message-observation resource witnesses."""
import os
import pathlib


def sample(pid):
    root = pathlib.Path(f"/proc/{pid}")
    fields = dict(line.split(":", 1) for line in (root / "status").read_text().splitlines())
    descriptors = []
    for descriptor in (root / "fd").iterdir():
        try:
            descriptors.append(os.readlink(descriptor))
        except FileNotFoundError:
            pass  # The independently polling activity reader closed its socket.
    return {"rss_kib": int(fields["VmRSS"].split()[0]),
        "peak_kib": int(fields["VmHWM"].split()[0]), "fds": len(descriptors),
        "retained_fds": sum(not descriptor.startswith("socket:") for descriptor in descriptors),
        "sockets": sum(descriptor.startswith("socket:") for descriptor in descriptors)}
