"""Synthetic token-text/SSE fixture; body offsets are independent of framing chunks."""
import functools

def delta(index, tokens):
    return (f'event: response.output_text.delta\ndata: {{"type":"response.output_text.delta","sequence_number":"{index:05d}","delta":"'+ 'text'*tokens +'"}\n\n').encode()

def terminal_head(events):
    return f'event: response.completed\ndata: {{"type":"response.completed","sequence_number":"{events:05d}","response":{{"status":"completed","text":"'.encode()

TAIL=b'"}}\n\n'

def dimensions(tokens, events):
    return len(delta(0,tokens)), len(terminal_head(events))+events*tokens*4+len(TAIL)

@functools.lru_cache(maxsize=16)
def body(offset, length, tokens, events):
    # At most 16 chunks of <=16 KiB; never construct a whole response.
    assert length<=16384
    record_len,terminal_len=dimensions(tokens,events)
    total_delta=record_len*events;head=terminal_head(events)
    out=bytearray()
    while length:
        if offset<total_delta:
            index,pos=divmod(offset,record_len);chunk=delta(index,tokens)[pos:pos+length]
        else:
            pos=offset-total_delta
            if pos<len(head):chunk=head[pos:pos+length]
            elif pos<len(head)+events*tokens*4:
                textpos=pos-len(head);take=min(length,events*tokens*4-textpos)
                chunk=(b'text'*((take+7)//4))[textpos%4:textpos%4+take]
            else:chunk=TAIL[pos-len(head)-events*tokens*4:][:length]
        assert chunk
        out.extend(chunk);offset+=len(chunk);length-=len(chunk)
    return bytes(out)
