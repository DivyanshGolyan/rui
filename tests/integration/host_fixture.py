import json
import os

from control_fixture import raw_request
import host_process
import os_semantics
from host_process import dispose_all, stop_process


def dispose_endpoint(process, endpoint, thread, timeout):
    def shutdown():
        if thread.ident is not None:
            try:
                endpoint.shutdown()
            except BaseException:
                dispose_all(endpoint.shutdown)
                raise

    def join():
        if thread.ident is not None:
            thread.join(timeout=timeout)
            assert not thread.is_alive(), "Endpoint thread did not retire"

    dispose_all(
        lambda: stop_process(process) if process is not None else None,
        shutdown,
        endpoint.server_close,
        join,
    )


def host_resources(pid):
    memory = os_semantics.process_memory(pid)
    if memory is None:
        return None
    return memory["rss_kib"] * 1024, len(os_semantics.descriptor_links(pid))


def provider_connections(pid, port):
    inodes = {row[9] for rows in (os_semantics.socket_table("tcp"), os_semantics.socket_table("tcp6")) if rows is not None
              for row in rows if int(row[2].rsplit(":", 1)[1], 16) == port}
    count = 0
    for fd in os_semantics.descriptor_links(pid):
        try:
            target = os.readlink(fd)
        except FileNotFoundError:
            continue
        count += target.startswith("socket:[") and target[8:-1] in inodes
    return count


def idle_resources(pid, path):
    try:
        descriptors = {fd.name: os.readlink(fd) for fd in os_semantics.descriptor_links(pid)}
        unix = os_semantics.socket_table("unix")
        if unix is None: return None
        peers = {f"socket:[{r[6]}]" for r in unix if len(r) == 8 and r[7] == path and int(r[3], 16) == 0}
        if any(target in peers for target in descriptors.values()): return None
        if descriptors != {fd.name: os.readlink(fd) for fd in os_semantics.descriptor_links(pid)}: return None
    except FileNotFoundError: return None
    return host_resources(pid)[0], len(descriptors)


def request(socket_path, store, route, kind, session, **fields):
    body = json.dumps(
        {"version": host_process.WIRE_VERSION, "kind": kind, "store": str(store), "session": session, **fields},
        separators=(",", ":"),
    ).encode()
    return raw_request(socket_path, route, body)


CONVERSATION_KINDS = ("user", "assistant", "tool_result", "hosted_call")


def conversation_rows(socket_path, store, session, kinds=CONVERSATION_KINDS):
    """Every Activity row of these kinds, oldest first: forward pages of one captured end."""
    rows, end, position, ordinal = [], None, "0", None
    while True:
        head, body = request(socket_path, store, "/v1/activity-page", "activity_page", session,
            end=end, position=position, ordinal=ordinal, direction="forward", kinds=list(kinds), limit="16")
        assert head.startswith(b"HTTP/1.1 200 "), (head, body)
        page = json.loads(body)
        rows += page["items"]
        if not page["more"]:
            return rows
        last = page["items"][-1]
        end, position, ordinal = page["end"], last["position"], last["ordinal"]


def row_kind(row):
    return next(iter(row["value"]))
