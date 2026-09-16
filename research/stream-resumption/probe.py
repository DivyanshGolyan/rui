#!/usr/bin/env python3
"""Opt-in subscription stream probe; synthetic input, no tools or credential writes.

Run create with a fresh checkpoint path, then resume/retrieve with the same path:
  python3 research/stream-resumption/probe.py --live --action create --mode ordinary \
    --checkpoint /tmp/resumption-new.json --results /tmp/resumption-new.jsonl
  python3 research/stream-resumption/probe.py --live --action resume --mode ordinary \
    --checkpoint /tmp/resumption-new.json --results /tmp/resumption-new.jsonl
  python3 research/stream-resumption/probe.py --live --action retrieve --mode ordinary \
    --checkpoint /tmp/resumption-new.json --results /tmp/resumption-new.jsonl

Create exits 73 after persisting the first text event's cursor, without cleanup.
The saved cursor is experimental metadata, not a production payload checkpoint.
Use --mode background or stored with a new checkpoint to test those parameters.
No automatic retries; 90-second lifetime and byte limits are experiment bounds.
"""
import argparse
import http.client
import json
import os
from pathlib import Path
import signal
import time
from datetime import datetime, timezone
from urllib.parse import quote


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--live', action='store_true', required=True)
    parser.add_argument('--action', choices=['create', 'retrieve', 'resume'], required=True)
    parser.add_argument('--mode', choices=['ordinary', 'stored', 'background', 'stored-background'], default='background')
    parser.add_argument('--model', default='gpt-6-astra')
    parser.add_argument('--checkpoint', type=Path, required=True)
    parser.add_argument('--results', type=Path, required=True)
    args = parser.parse_args()
    tokens = json.loads((Path.home() / '.codex/auth.json').read_text())['tokens']
    # Credentials remain in process memory. Never refresh or change account state.
    headers = {
        'Authorization': 'Bearer ' + tokens['access_token'],
        'ChatGPT-Account-Id': tokens['account_id'],
        'Originator': 'onepage', 'Accept': 'text/event-stream',
        'Content-Type': 'application/json', 'Accept-Encoding': 'identity',
        'OpenAI-Beta': 'responses=experimental',
    }
    args.results.parent.mkdir(parents=True, exist_ok=True)
    log = args.results.open('a')

    def emit(**row):
        row = {'utc': datetime.now(timezone.utc).isoformat(), 'action': args.action, 'mode': args.mode, **row}
        line = json.dumps(row, separators=(',', ':'))
        log.write(line + '\n')
        log.flush()
        os.fsync(log.fileno())
        print(line, flush=True)

    def save(row):
        # This experiment's checkpoint contains identifiers and counters only.
        with args.checkpoint.open('x') as output:
            json.dump(row, output)
            output.flush()
            os.fsync(output.fileno())

    def safe_error(body):
        try:
            parsed = json.loads(body)
            error = parsed.get('error', parsed.get('detail', {}))
            if isinstance(error, dict):
                result = {key: error[key] for key in ('type', 'code', 'param', 'message') if key in error}
            elif isinstance(error, str):
                result = {'message': error}
            else:
                return {'error_shape': type(error).__name__}
            text = json.dumps(result)
            for value in tokens.values():
                if isinstance(value, str) and value:
                    text = text.replace(value, '[redacted]')
            return {'error': text[:1000]}
        except (ValueError, AttributeError):
            return {'error_body_bytes': len(body)}

    def deadline(_signum, _frame):
        raise TimeoutError()

    signal.signal(signal.SIGALRM, deadline)
    signal.alarm(90)
    connection = http.client.HTTPSConnection('chatgpt.com', timeout=30)
    path = '/backend-api/codex/responses'
    body = None
    checkpoint = None
    if args.action == 'create':
        body = {
            'model': args.model,
            'instructions': 'Answer this synthetic transport test. No tools are available.',
            'input': [{'role': 'user', 'content': [{'type': 'input_text', 'text':
                'Describe how rain forms in about 300 words. Use plain prose. Do not use tools.'}]}],
            'reasoning': {'effort': 'low'}, 'stream': True,
            'store': args.mode in ('stored', 'stored-background'),
        }
        if args.mode in ('background', 'stored-background'):
            body['background'] = True
        emit(kind='request', requested_model=args.model, background=body.get('background', False), store=body['store'])
        body = json.dumps(body).encode()
    else:
        checkpoint = json.loads(args.checkpoint.read_text())
        path += '/' + quote(checkpoint['response_id'], safe='')
        if args.action == 'resume':
            path += '?stream=true&starting_after=' + str(checkpoint['sequence_number'])
        else:
            headers['Accept'] = 'application/json'
        emit(kind='request', response_id=checkpoint['response_id'], starting_after=checkpoint['sequence_number'] if args.action == 'resume' else None)
    start = time.monotonic()
    try:
        connection.request('POST' if args.action == 'create' else 'GET', path, body, headers)
        response = connection.getresponse()
        emit(kind='headers', http_status=response.status, content_type=response.getheader('Content-Type'),
             request_id=response.getheader('x-request-id'), served_model=response.getheader('openai-model'),
             elapsed_s=round(time.monotonic() - start, 3))
        if response.status != 200:
            emit(kind='rejection', **safe_error(response.read(65536)))
            return
        if args.action == 'retrieve':
            data = response.read(2 * 1024 * 1024 + 1)
            if len(data) > 2 * 1024 * 1024:
                raise ValueError('experiment body bound')
            data = json.loads(data)
            emit(kind='retrieved', response_id=data.get('id'), same_response=data.get('id') == checkpoint['response_id'],
                 status=data.get('status'), background=data.get('background'), store=data.get('store'))
            return
        response_id = None
        event_count = 0
        total = 0
        for_line_limit = 2 * 1024 * 1024
        while True:
            line = response.readline(for_line_limit + 1)
            total += len(line)
            if len(line) > for_line_limit or total > 8 * 1024 * 1024:
                raise ValueError('experiment stream bound')
            if not line:
                emit(kind='eof_without_terminal', events=event_count)
                return
            if not line.startswith(b'data:') or line[5:].strip() == b'[DONE]':
                continue
            event = json.loads(line[5:])
            event_count += 1
            kind = event.get('type')
            data = event.get('response', {})
            response_id = data.get('id', response_id)
            if kind == 'response.created':
                emit(kind='created', response_id=response_id, background=data.get('background'),
                     store=data.get('store'), status=data.get('status'), reported_model=data.get('model'))
            if args.action == 'create' and kind == 'response.output_text.delta':
                saved = {'response_id': response_id, 'sequence_number': event['sequence_number'], 'mode': args.mode}
                save(saved)
                emit(kind='hard_exit_after_first_text_delta', **saved, events=event_count, exit_code=73)
                # No HTTP cleanup or cancel request: terminate the connection-owning process.
                os._exit(73)
            if kind in ('response.completed', 'response.failed', 'response.incomplete', 'error'):
                emit(kind='terminal', event=kind, response_id=response_id,
                     same_response=response_id == checkpoint['response_id'] if checkpoint else None,
                     events=event_count, **(safe_error(json.dumps(event).encode()) if kind == 'error' else {}))
                return
    except Exception as exc:
        # Exception messages can include credential-bearing request state.
        emit(kind='exception', exception_type=type(exc).__name__)
    finally:
        signal.alarm(0)
        connection.close()
        log.close()


if __name__ == '__main__':
    main()
