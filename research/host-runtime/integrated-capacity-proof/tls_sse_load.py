import argparse
import asyncio
import json
import resource
import signal
import ssl
import time


class Counters:
    accepted = 0
    completed = 0
    disconnected = 0
    wire_bytes = 0
    events = 0
    first_disconnect_seconds = None
    last_disconnect_seconds = None
    streaming_done = 0


ALL_CONNECTED = asyncio.Event()
ALL_STREAMS_READY_TO_TERMINATE = asyncio.Event()
START_AT = None
TERMINAL_AT = None


async def write_fragmented(writer, payload: bytes, stream_id: int, sequence: int):
    if ARGS.fragment == "none":
        writer.write(payload)
        await writer.drain()
        return

    # Deterministic awkward boundaries, including within the SSE field prefix and JSON.
    first = 1 + ((stream_id + sequence) % 7)
    second = min(len(payload), first + 1 + ((stream_id * 3 + sequence) % 19))
    writer.write(payload[:first])
    await writer.drain()
    await asyncio.sleep(0)
    writer.write(payload[first:second])
    await writer.drain()
    await asyncio.sleep(0)
    writer.write(payload[second:])
    await writer.drain()


async def handle(reader, writer):
    global START_AT, TERMINAL_AT
    stream_id = 0
    try:
        head = await reader.readuntil(b"\r\n\r\n")
        content_length = 0
        for line in head.split(b"\r\n"):
            if line.lower().startswith(b"content-length:"):
                content_length = int(line.split(b":", 1)[1].strip())
        if content_length:
            await reader.readexactly(content_length)

        Counters.accepted += 1
        stream_id = Counters.accepted
        if Counters.accepted == ARGS.expected_connections:
            START_AT = asyncio.get_running_loop().time() + 0.1
            ALL_CONNECTED.set()
        await ALL_CONNECTED.wait()
        await asyncio.sleep(max(0, START_AT - asyncio.get_running_loop().time()))

        headers = (
            b"HTTP/1.1 200 OK\r\n"
            b"Content-Type: text/event-stream\r\n"
            b"Cache-Control: no-cache\r\n"
            b"Connection: close\r\n\r\n"
        )
        writer.write(headers)
        await writer.drain()
        Counters.wire_bytes += len(headers)

        interval = ARGS.batch_tokens / ARGS.tokens_per_second
        delta = "x" * (ARGS.batch_tokens * ARGS.chars_per_token)
        event = (
            'data: {"type":"response.output_text.delta","delta":"'
            + delta
            + '"}\n\n'
        ).encode()
        loop = asyncio.get_running_loop()
        deadline = loop.time() + ARGS.seconds
        sequence = 0
        next_send = loop.time()
        while next_send < deadline:
            wait = next_send - loop.time()
            if wait > 0:
                await asyncio.sleep(wait)
            await write_fragmented(writer, event, stream_id, sequence)
            Counters.wire_bytes += len(event)
            Counters.events += 1
            sequence += 1
            next_send += interval

        Counters.streaming_done += 1
        if Counters.streaming_done == ARGS.expected_connections:
            TERMINAL_AT = asyncio.get_running_loop().time() + 0.005
            ALL_STREAMS_READY_TO_TERMINATE.set()
        await ALL_STREAMS_READY_TO_TERMINATE.wait()
        await asyncio.sleep(max(0, TERMINAL_AT - asyncio.get_running_loop().time()))

        if ARGS.terminal_bytes:
            terminal_text = "t" * ARGS.terminal_bytes
            terminal = (
                'data: {"type":"response.output_item.done","item":{"type":"message",'
                '"role":"assistant","content":[{"type":"output_text","text":"'
                + terminal_text
                + '"}]}}\n\n'
            ).encode()
            await write_fragmented(writer, terminal, stream_id, sequence)
            Counters.wire_bytes += len(terminal)
            Counters.events += 1

        if not ARGS.omit_completed:
            completed = b'data: {"type":"response.completed","response":{"status":"completed"}}\n\n'
            await write_fragmented(writer, completed, stream_id, sequence + 1)
            Counters.wire_bytes += len(completed)
            Counters.events += 1
        Counters.completed += 1
    except (asyncio.IncompleteReadError, ConnectionError, ssl.SSLError, BrokenPipeError):
        Counters.disconnected += 1
        if START_AT is not None:
            elapsed = asyncio.get_running_loop().time() - START_AT
            if Counters.first_disconnect_seconds is None:
                Counters.first_disconnect_seconds = elapsed
            Counters.last_disconnect_seconds = elapsed
    finally:
        writer.close()
        try:
            await writer.wait_closed()
        except Exception:
            pass


async def main():
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(ARGS.cert, ARGS.key)
    server = await asyncio.start_server(
        handle,
        "127.0.0.1",
        ARGS.port,
        ssl=context,
        backlog=256,
    )
    loop = asyncio.get_running_loop()
    stop = asyncio.Event()
    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, stop.set)

    print(json.dumps({"ready": True, "port": ARGS.port}), flush=True)
    started = time.monotonic()
    async with server:
        serve = asyncio.create_task(server.serve_forever())
        await stop.wait()
        serve.cancel()
        try:
            await serve
        except asyncio.CancelledError:
            pass
    print(
        json.dumps(
            {
                "accepted": Counters.accepted,
                "completed": Counters.completed,
                "disconnected": Counters.disconnected,
                "events": Counters.events,
                "wire_bytes": Counters.wire_bytes,
                "wall_seconds": time.monotonic() - started,
                "cpu_seconds": resource.getrusage(resource.RUSAGE_SELF).ru_utime
                + resource.getrusage(resource.RUSAGE_SELF).ru_stime,
                "max_rss_bytes": resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,
                "first_disconnect_seconds": Counters.first_disconnect_seconds,
                "last_disconnect_seconds": Counters.last_disconnect_seconds,
            }
        ),
        flush=True,
    )


parser = argparse.ArgumentParser()
parser.add_argument("--cert", required=True)
parser.add_argument("--key", required=True)
parser.add_argument("--port", type=int, default=18443)
parser.add_argument("--seconds", type=float, default=10.0)
parser.add_argument("--tokens-per-second", type=float, default=100.0)
parser.add_argument("--chars-per-token", type=int, default=4)
parser.add_argument("--batch-tokens", type=int, default=1)
parser.add_argument("--terminal-bytes", type=int, default=65536)
parser.add_argument("--fragment", choices=("none", "split"), default="none")
parser.add_argument("--expected-connections", type=int, default=100)
parser.add_argument("--omit-completed", action="store_true")
ARGS = parser.parse_args()

asyncio.run(main())
