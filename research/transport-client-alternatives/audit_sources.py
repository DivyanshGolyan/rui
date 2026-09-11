#!/usr/bin/env python3
"""Retrieve immutable primary source and check mechanism symbols and recorded hashes."""
import argparse, concurrent.futures, datetime, hashlib, json, pathlib, urllib.request
BASE = 'https://raw.githubusercontent.com/'
SOURCES = [
 ('awslabs/aws-c-common/c4803685d3df70b1b2e0b929aeebf65e60c3847f/source/allocator.c', ['AWS_PANIC_OOM']),
 ('awslabs/aws-c-common/c4803685d3df70b1b2e0b929aeebf65e60c3847f/include/aws/common/assert.h', ['AWS_PANIC_OOM', 'abort()']),
 ('nghttp2/nghttp2/v1.70.0/lib/includes/nghttp2/nghttp2.h', ['nghttp2_option_set_no_auto_window_update', 'nghttp2_session_consume_connection', 'nghttp2_session_consume_stream', 'nghttp2_session_client_new3']),
 ('nghttp2/nghttp2/v1.70.0/lib/nghttp2_session.c', ['session_update_consumed_size']),
 ('curl/curl/curl-8_22_0/lib/http2.c', ['cf_h2_update_local_win']),
 ('curl/curl/curl-8_22_0/lib/transfer.c', ['Curl_retry_request', 'refused_stream']),
 ('awslabs/aws-c-http/2b563f8a7bd67a902a8b558bb44113748045877c/include/aws/http/connection.h', ['conn_manual_window_management', 'aws_http2_connection_update_window']),
 ('awslabs/aws-c-http/2b563f8a7bd67a902a8b558bb44113748045877c/source/h2_connection.c', ['conn_manual_window_management', 'AWS_ERROR_HTTP_GOAWAY_RECEIVED']),
 ('awslabs/aws-c-http/2b563f8a7bd67a902a8b558bb44113748045877c/include/aws/http/request_response.h', ['aws_http_stream_update_window', 'aws_http_stream_cancel']),
 ('awslabs/aws-c-io/c2d222b73000ddcc5aeed837f4434560a47bad47/source/s2n/s2n_tls_channel_handler.c', ['aws_mem_acquire', 's2n_mem_set_callbacks']),
 ('h2o/h2o/cac7e6568ad98a848f099ecd0a18b881f632479a/lib/common/http2client.c', ['h2o_buffer_append', 'update_window']),
]
p=argparse.ArgumentParser(); p.add_argument('--verify', action='store_true'); a=p.parse_args()
path=pathlib.Path(__file__).with_name('source-evidence.json')
def fetch(item):
    source, symbols=item
    data=urllib.request.urlopen(BASE+source, timeout=30).read()
    content=data.decode()
    for symbol in symbols:
        if symbol not in content: raise ValueError(f'{source}: missing {symbol}')
    return dict(url=BASE+source, sha256=hashlib.sha256(data).hexdigest(), bytes=len(data), checked_symbols=symbols)
with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
    rows=list(pool.map(fetch, SOURCES))
if a.verify:
    assert rows == json.loads(path.read_text())['sources'], 'source evidence changed'
else:
    if path.exists(): raise SystemExit('refusing to overwrite evidence')
    path.write_text(json.dumps(dict(retrieved_utc=datetime.datetime.now(datetime.timezone.utc).isoformat(), sources=rows), indent=2)+'\n')
print(f'Checked {len(rows)} pinned primary-source files')

pin=json.loads(path.with_name('header-pin.json').read_text())
template=urllib.request.urlopen(pin['template_url'], timeout=30).read()
assert hashlib.sha256(template).hexdigest() == pin['template_sha256'], 'version template changed'
generated=template.replace(b'@PACKAGE_VERSION@', pin['version'].encode()).replace(b'@PACKAGE_VERSION_NUM@', pin['version_num'].encode())
assert hashlib.sha256(generated).hexdigest() == pin['generated_header_sha256'], 'generated version header differs'
print('Checked pinned template and generated nghttp2 version header')
