#!/usr/bin/env python3
"""SH-131: ordinary start hands an older Host over to the current build."""
import json
import os
import pathlib
import shlex
import shutil
import subprocess
import sys
import tempfile
import threading

import bash_fixture
import host_process
import model_fixture
import os_semantics
from host_process import dispose_all, start_ready_process, wait_for

CURRENT = None
OLDER = None
CAPACITY = 2


def run(binary, env, *args, check=True):
    result = subprocess.run([str(binary), *map(str, args)], env=env, text=True,
                            capture_output=True, timeout=30)
    if check:
        assert result.returncode == 0, (result.args, result.returncode, result.stdout, result.stderr)
    return result


def status(binary, env, store):
    return json.loads(run(binary, env, 'host', 'status', '--store', store).stdout)


def ready(binary, env, store):
    result = status(binary, env, store)
    return result if result['status'] == 'ready' else None


def verify(before, after, store):
    assert before['status'] == after['status'] == 'ready', (before, after)
    assert before['instance'] != after['instance'], (before, after)
    assert before['store'] == after['store'] == str(store.resolve()), (before, after)
    assert before['active_capacity'] == after['active_capacity'] == str(CAPACITY), (before, after)
    assert len(after['instance']) == 32, after


def peer_pid(socket_path):
    with os_semantics.unix_stream() as connection:
        connection.connect(str(socket_path))
        return os_semantics.socket_peer_pid(connection)


def case(root, runtime, kind):
    home = root / 'home'
    home.mkdir(mode=0o700)
    store = root / 'store'
    state = root / 'state'
    state.mkdir(mode=0o700)
    managed = home / '.local/lib/rui'
    actors = []
    for name, source in (('current', CURRENT), ('older', OLDER)):
        build = managed / name
        (build / 'bin').mkdir(parents=True)
        target = build / 'bin/rui'
        shutil.copy2(source, target)
        (build / 'THIRD_PARTY_NOTICES.md').write_text('Synthetic fixture notices\n')
        actors.append(target)
    current, older = actors
    link = home / '.local/bin/rui'
    link.parent.mkdir(parents=True)
    link.symlink_to(current)
    gate = root / 'after-stop.gate'
    gate.touch(mode=0o600)
    env = {**os.environ, 'HOME': str(home), 'RUI_TEST_UPGRADE_BEFORE_START_GATE': str(gate)}
    old_env = os.environ.copy()
    os.environ.update(env)
    model_fixture.RUI = older
    host = caller = endpoint = thread = None
    socket_path = None
    try:
        provider = None
        if kind == 'host-owned':
            responses = []
            command = f'{shlex.quote(str(current))} host start --store {shlex.quote(str(store))}'
            bash_fixture.add_exchange(responses, kind, command, timeout_ms=60000)
            endpoint = model_fixture.SuccessEndpoint(responses)
            thread = threading.Thread(target=endpoint.serve_forever, daemon=True)
            thread.start()
            provider = f'http://127.0.0.1:{endpoint.server_port}/responses'
        run(older, env, 'host', 'set', '--store', store, 'interface.dir', runtime)
        args = model_fixture.host_arguments(store, provider, active_capacity=CAPACITY)
        host, fields = start_ready_process(args, env=env)
        socket_path = pathlib.Path(fields["socket"])
        assert peer_pid(socket_path) == host.pid
        before = status(older, env, store)
        assert before['active_capacity'] == str(CAPACITY), before
        if kind == 'host-owned':
            session = bash_fixture.configure(state, store, 'configure', permission='bypass')
            model_fixture.message(state, store, 'message', session, 'execute')
        else:
            caller = subprocess.Popen([str(current), 'host', 'start', '--store', str(store)],
                                      env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        def reached():
            if caller is not None and caller.poll() is not None:
                raise AssertionError(('caller exited before post-stop gate', caller.communicate()))
            return gate.with_name(gate.name + '.entered').exists()
        wait_for(reached, 'handover post-stop gate', timeout=40)
        assert host.poll() is not None, 'old Host has not retired at post-stop gate'
        if kind == 'caller-departs':
            caller.kill()
            caller.wait(timeout=5)
        gate.unlink()
        after = wait_for(lambda: ready(current, env, store), 'replacement Host', timeout=40)
        verify(before, after, store)
        assert os_semantics.process_executable(peer_pid(socket_path)) == current
        if kind == 'independent':
            out, err = caller.communicate(timeout=30)
            assert caller.returncode == 0, (caller.returncode, out, err)
            report = json.loads(out)
            assert report['instance'] == after['instance'] and report['active_capacity'] == str(CAPACITY), report
        assert status(current, env, store)['instance'] == after['instance']
    finally:
        entered = gate.with_name(gate.name + '.entered').exists()
        gate.unlink(missing_ok=True)
        if caller is not None and caller.poll() is None:
            caller.communicate(timeout=40)
        # Once retirement has happened the handover owns the replacement even
        # if its original caller has departed; let it finish before cleanup.
        if entered and host is not None and host.poll() is not None:
            wait_for(lambda: ready(current, env, store), 'replacement before cleanup', timeout=40)
        if socket_path is not None:
            try:
                pid = peer_pid(socket_path)
            except (FileNotFoundError, ConnectionRefusedError):
                pid = None
            if pid is not None:
                executable = os_semantics.process_executable(pid)
                assert executable in actors, (pid, executable)
                observed = status(executable, env, store)
                assert observed['status'] == 'ready', observed
                receipt = json.loads(run(executable, env, 'host', 'pause', '--store', store,
                                         '--instance', observed['instance']).stdout)
                assert receipt['status'] == 'acknowledged' and receipt['store'] == str(store.resolve()), receipt
                assert receipt['instance'] == observed['instance'], receipt
                assert receipt['retirement'] == 'confirmed', receipt
                def retired():
                    if status(executable, env, store)['status'] != 'unavailable':
                        return False
                    try:
                        peer = peer_pid(socket_path)
                    except (FileNotFoundError, ConnectionRefusedError):
                        return True
                    raise AssertionError(('private socket still has a Host after pause', pid, peer))
                wait_for(retired, 'private Host retirement after pause', timeout=30)
        if host is not None:
            host.wait(timeout=30)
        if endpoint is not None:
            dispose_all(endpoint.shutdown, endpoint.server_close, lambda: thread.join(timeout=5))
            assert not thread.is_alive()
        os.environ.clear()
        os.environ.update(old_env)


def sh_131_ordinary_start_handover_survives_caller_custody_and_departure():
    host_process.enter()
    global CURRENT, OLDER
    CURRENT = pathlib.Path(sys.argv[1]).resolve(strict=True)
    OLDER = pathlib.Path(sys.argv[2]).resolve(strict=True)
    with tempfile.TemporaryDirectory(prefix='rui-handover-') as directory:
        root = pathlib.Path(directory).resolve()
        for kind in ('independent', 'host-owned', 'caller-departs'):
            case_root = root / kind
            case_root.mkdir(mode=0o700)
            runtime = pathlib.Path(tempfile.mkdtemp(prefix='rui-if-', dir=host_process.canonical_fixture_root('/tmp'))).resolve()
            # Keep the private interface if cleanup fails; deleting it could hide a live Host.
            case(case_root, runtime, kind)
            shutil.rmtree(runtime)
            print(f'{kind}: replacement identity and capacity verified')


if __name__ == '__main__':
    sh_131_ordinary_start_handover_survives_caller_custody_and_departure()
