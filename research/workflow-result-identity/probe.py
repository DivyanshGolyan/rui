#!/usr/bin/env python3
"""Check keyed result composition in an existing evaluator; no Host or model I/O."""
import hashlib
import json
from pathlib import Path
import struct
import subprocess

ROOT = Path(__file__).resolve().parents[2]
EXE = ROOT / 'zig-out/bin/rui-workflow-evaluator'


def string(value):
    raw = value.encode()
    return struct.pack('<I', len(raw)) + raw


def data(value):
    if value is None:
        return b'\0'
    if isinstance(value, str):
        return b'\4' + string(value)
    if isinstance(value, list):
        return b'\5' + struct.pack('<I', len(value)) + b''.join(map(data, value))
    if isinstance(value, dict):
        return b'\6' + struct.pack('<I', len(value)) + b''.join(
            string(key) + data(item) for key, item in value.items())
    raise TypeError(value)


class Reader:
    def __init__(self, raw):
        self.raw, self.offset = raw, 0

    def take(self, size):
        result = self.raw[self.offset:self.offset + size]
        assert len(result) == size
        self.offset += size
        return result

    def number(self, size):
        return int.from_bytes(self.take(size), 'little')

    def string(self):
        return self.take(self.number(4)).decode()

    def data(self):
        tag = self.number(1)
        if tag == 0:
            return None
        if tag in (1, 2):
            return tag == 2
        if tag == 3:
            return struct.unpack('<d', self.take(8))[0]
        if tag == 4:
            return self.string()
        if tag == 5:
            return [self.data() for _ in range(self.number(4))]
        if tag == 6:
            return {self.string(): self.data() for _ in range(self.number(4))}
        raise ValueError(tag)


def evaluate(source, visible=None):
    visible = visible or {}
    frame = b'OPWE\1\0' + string(source) + data(None) + struct.pack('<H', len(visible))
    for key, (kind, value) in visible.items():
        frame += string(key) + bytes([kind]) + (data(value) if kind == 0 else string(value))
    process = subprocess.run([str(EXE)], input=frame, capture_output=True, timeout=10)
    assert process.returncode == 0, process.stderr.decode()
    reader = Reader(process.stdout)
    assert reader.take(6) == b'OPWO\1\0'
    tag = reader.number(1)
    if tag == 0:
        result = {'completed': reader.data()}
    elif tag == 1:
        result = {'blocked': [Reader(reader.take(reader.number(4))).data()
                              for _ in range(reader.number(2))]}
    else:
        result = {'error_tag': tag, 'error': reader.string()}
    assert reader.offset == len(reader.raw)
    return result


SEQUENTIAL = '''export default async function ({agent}) {
  const draft = await agent({key: "draft", task: "Draft", input: {session: "writer"}});
  const revised = await agent({key: "revise", task: "Revise", input: {session: "writer", draft}});
  return {draft, revised};
}'''


def main():
    checks = {}
    first = evaluate(SEQUENTIAL)
    assert [request['key'] for request in first['blocked']] == ['draft']
    checks['initial_submission'] = first

    second = evaluate(SEQUENTIAL, {'draft': (0, 'original draft')})
    assert second == {'blocked': [{'key': 'revise', 'task': 'Revise',
                                  'input': {'session': 'writer', 'draft': 'original draft'}}]}
    checks['fresh_evaluator_recovers_draft_for_revision'] = second

    visible = {'draft': (0, 'original draft'), 'revise': (0, {'text': 'revised answer'})}
    completed = evaluate(SEQUENTIAL, visible)
    assert completed == {'completed': {'draft': 'original draft', 'revised': {'text': 'revised answer'}}}
    checks['both_results_recover_without_new_requests'] = completed
    assert evaluate(SEQUENTIAL, visible) == completed
    checks['repeat_completed_evaluation'] = 'passed'

    aliases = '''export default async function ({agent}) {
      const submit = (key) => agent({key, task: key, input: {session: "writer"}});
      const alias = submit;
      const a = submit("a"); const b = alias("b");
      return await Promise.all([a, b, a]);
    }'''
    result = evaluate(aliases, {'a': (0, 'A'), 'b': (0, 'B')})
    assert result == {'completed': ['A', 'B', 'A']}
    checks['aliases_and_reawait_keep_operation_identity'] = result

    recover = '''export default async function ({agent}) {
      try { return await agent({key: "draft", task: "Draft"}); }
      catch (error) { return {code: error.code, key: error.turn_key}; }
    }'''
    # This existing artifact uses Turn names; current source uses Job names.
    # Deliberately test the recorded artifact protocol, not claim a fresh build.
    for code in ('TurnFailed', 'TurnCancelled'):
        result = evaluate(recover, {'draft': (1, code)})
        assert result == {'completed': {'code': code, 'key': 'draft'}}
        checks['cached_' + code.lower()] = result

    conflict = '''export default async function ({agent}) {
      return await Promise.all([agent({key: "same", task: "Draft"}),
                                agent({key: "same", task: "Revise"})]);
    }'''
    result = evaluate(conflict)
    assert result.get('error') == 'TurnRequestInvalid'
    checks['same_evaluation_changed_binding_rejected'] = result

    print(json.dumps({
        'scope': 'Existing native evaluator only. Visible outcomes are fixture inputs; session is ordinary input data.',
        'probe_sha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        'executable_sha256': hashlib.sha256(EXE.read_bytes()).hexdigest(),
        'checks': checks,
    }, indent=2))


if __name__ == '__main__':
    main()
