"""One Linux /proc sample of a process's memory and descriptors, shared by the
saved-request and message-observation resource witnesses."""
import os

import os_semantics


def sample(pid):
    memory = os_semantics.process_memory(pid)
    assert memory is not None, f"process {pid} has no Linux process record"
    descriptors = []
    for descriptor in os_semantics.descriptor_links(pid):
        try:
            descriptors.append(os.readlink(descriptor))
        except FileNotFoundError:
            pass  # The independently polling activity reader closed its socket.
    return {"rss_kib": memory["rss_kib"],
        "peak_kib": memory["peak_kib"], "fds": len(descriptors),
        "retained_fds": sum(not descriptor.startswith("socket:") for descriptor in descriptors),
        "sockets": sum(descriptor.startswith("socket:") for descriptor in descriptors)}
