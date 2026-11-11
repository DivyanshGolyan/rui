"""Validate the complete stored-byte Bash frame before testing its model-facing body."""


def result_body(text):
    raw = text.encode("utf-8")
    header, newline, body = raw.partition(b"\n")
    prefix = b"RUI-BASH-RESULT/1 "
    assert newline and header.startswith(prefix), ("missing Bash result frame", text)
    fields = header[len(prefix):].split(b" ")
    assert len(fields) == 5, ("invalid Bash span count", header)
    lengths = []
    for field in fields:
        assert field and all(48 <= digit <= 57 for digit in field), ("invalid Bash span length", header)
        length = int(field)
        assert length <= (1 << 64) - 1, ("overflowed Bash span", header)
        lengths.append(length)
    assert len(body) == sum(lengths), ("Bash frame length mismatch", lengths, len(body))
    offset = 0
    for length in lengths:
        # All boundaries are stored UTF-8 byte boundaries, not character offsets.
        body[offset:offset + length].decode("utf-8")
        offset += length
    return body.decode("utf-8")
