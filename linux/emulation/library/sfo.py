from __future__ import annotations

import re
import struct

_PSF_MAGIC = b"\x00PSF"
_FMT_UTF8 = 0x0204
_FMT_INT32 = 0x0404
_VITA_TITLE_ID = re.compile(r"^[A-Z]{4}\d{5}$")


def parse(data: bytes) -> dict[str, str | int]:
    """Parse a PSF/SFO blob (param.sfo) into a key/value dict.

    Raises ValueError on any structural inconsistency; SFO content comes from
    untrusted archives.
    """
    if len(data) < 20 or data[0:4] != _PSF_MAGIC:
        raise ValueError("not an SFO blob")
    key_table, data_table, entries = struct.unpack_from("<III", data, 8)
    if entries > 4096:
        raise ValueError("SFO entry count out of range")
    result: dict[str, str | int] = {}
    for index in range(entries):
        offset = 20 + index * 16
        if offset + 16 > len(data):
            raise ValueError("SFO index table truncated")
        key_off, fmt, length, _max_len, data_off = struct.unpack_from(
            "<HHIII", data, offset
        )
        key_start = key_table + key_off
        key_end = data.find(b"\x00", key_start)
        if key_start >= len(data) or key_end < 0:
            raise ValueError("SFO key table truncated")
        key = data[key_start:key_end].decode("utf-8", errors="replace")
        value_start = data_table + data_off
        value_end = value_start + length
        if value_end > len(data):
            raise ValueError("SFO data table truncated")
        raw = data[value_start:value_end]
        if fmt == _FMT_INT32 and length >= 4:
            result[key] = struct.unpack_from("<i", raw)[0]
        else:
            result[key] = raw.rstrip(b"\x00").decode("utf-8", errors="replace")
    return result


def is_vita_title_id(value: object) -> bool:
    return isinstance(value, str) and bool(_VITA_TITLE_ID.match(value))


def build(entries: dict[str, str | int]) -> bytes:
    """Build a minimal SFO blob. Used by tests and fixtures only."""
    keys = list(entries)
    key_blob = b""
    key_offsets: list[int] = []
    for key in keys:
        key_offsets.append(len(key_blob))
        key_blob += key.encode("utf-8") + b"\x00"
    data_blob = b""
    index = b""
    for key, key_off in zip(keys, key_offsets):
        value = entries[key]
        if isinstance(value, int):
            raw = struct.pack("<i", value)
            fmt, length, max_len = _FMT_INT32, 4, 4
        else:
            raw = value.encode("utf-8") + b"\x00"
            fmt, length, max_len = _FMT_UTF8, len(raw), len(raw)
        index += struct.pack("<HHIII", key_off, fmt, length, max_len, len(data_blob))
        data_blob += raw
    key_table = 20 + len(index)
    data_table = key_table + len(key_blob)
    header = _PSF_MAGIC + struct.pack("<IIII", 0x101, key_table, data_table, len(keys))
    return header + index + key_blob + data_blob
