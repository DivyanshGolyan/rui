"""Synthetic request selector. No SQLite import or database access.

Small fixture JSON objects are decoded up to 64 KiB. Large-object JSON
transformation is deliberately NOT established by this interface experiment.
The returned request is a test oracle value, not production request storage.
"""
import json
from core import ResourceExceeded, Unavailable


def value(view, ref):
    body = bytearray()
    for chunk in view.chunks(ref):
        if len(body) + len(chunk) > 65536:
            raise ResourceExceeded('fixture JSON decoder')
        body.extend(chunk)
    return json.loads(body)


def selected(view):
    base = None
    for kind,ref in view.history():
        if kind == 'compaction': base = ref
    if base is None:
        for kind,ref in view.history(): yield kind,ref,False
        return
    for kind,ref in view.history(compaction=base):
        if kind in ('user','instruction'): yield kind,ref,False
    yield 'compaction',base,True
    for kind,ref in view.history(compaction=base,suffix=True):
        if ref != base: yield kind,ref,False


def request(view, rules='normal'):
    assert rules in ('normal','omit-visible-summary','explicit-reset')
    settings = value(view,view.settings())
    output = []
    records = ((kind,ref,False) for kind,ref in view.history()) if rules=='explicit-reset' else selected(view)
    for kind, ref, anchored in records:
        if kind in ('user','instruction'):
            output.append(value(view,ref))
            continue
        if rules == 'explicit-reset':
            # Synthetic policy retains ALL host input, omits prior provider output.
            # This is not claimed to be a supported Codex continuation mode.
            continue
        for payload in view.model_output(ref, from_anchor=anchored):
            item = value(view,payload)
            item.pop('created_by',None)
            if item['type'] in ('reasoning','compaction') and not item.get('encrypted_content'):
                raise Unavailable('required private continuation')
            if rules == 'omit-visible-summary' and item['type'] == 'reasoning':
                item['summary'] = []
            output.append(item)
        # Second bounded traversal supplies results in original call order,
        # rather than completion order or interleaved between output items.
        for payload in view.model_output(ref, from_anchor=anchored):
            item = value(view,payload)
            if item['type'] == 'function_call':
                result = view.tool_result(item['call_id'])
                if result is None:
                    raise Unavailable('tool result not visible')
                output.append(value(view,result))
    return {'settings':settings,'input':output}
