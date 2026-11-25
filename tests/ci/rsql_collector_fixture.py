import struct


def elf(*records):
    names = bytearray(b"\0")
    offsets = []
    for index in range(len(records)):
        offsets.append(len(names))
        names.extend(f"rsqlstmt_fixture_{index}".encode() + b"\0")
    start = 64 + 4 * 64
    symbol_offset = start + len(names)
    data_offset = symbol_offset + len(records) * 24
    payload = b"".join(records)
    image = bytearray(data_offset + len(payload))
    image[:6] = b"\x7fELF\x02\x01"
    struct.pack_into("<Q", image, 0x28, 64)
    struct.pack_into("<HH", image, 0x3a, 64, 4)
    section = struct.Struct("<IIQQQQIIQQ")
    section.pack_into(image, 64 + 64, 0, 3, 0, 0, start, len(names), 0, 0, 1, 0)
    section.pack_into(image, 64 + 2 * 64, 0, 2, 0, 0, symbol_offset, len(records) * 24, 1, 0, 8, 24)
    section.pack_into(image, 64 + 3 * 64, 0, 1, 0, 4096, data_offset, len(payload), 0, 0, 1, 0)
    image[start:symbol_offset] = names
    offset = 0
    for index, record in enumerate(records):
        struct.pack_into("<IBBHQQ", image, symbol_offset + index * 24, offsets[index], 0, 0, 3,
                         4096 + offset, len(record))
        offset += len(record)
    image[data_offset:] = payload
    return image
