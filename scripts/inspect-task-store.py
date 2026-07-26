#!/usr/bin/env python3
"""Read-only diagnostic for TaskForge's MessagePack task store."""

from __future__ import annotations

import argparse
import json
import struct
from pathlib import Path


class Decoder:
    def __init__(self, data: bytes) -> None:
        self.data = data
        self.offset = 0

    def take(self, count: int) -> bytes:
        end = self.offset + count
        if end > len(self.data):
            raise EOFError(f"offset={self.offset} count={count}")
        value = self.data[self.offset:end]
        self.offset = end
        return value

    def number(self, fmt: str, count: int):
        return struct.unpack(fmt, self.take(count))[0]

    def decode(self):
        prefix = self.take(1)[0]
        if prefix <= 0x7F:
            return prefix
        if prefix >= 0xE0:
            return prefix - 256
        if 0x80 <= prefix <= 0x8F:
            return {self.decode(): self.decode() for _ in range(prefix & 0x0F)}
        if 0x90 <= prefix <= 0x9F:
            return [self.decode() for _ in range(prefix & 0x0F)]
        if 0xA0 <= prefix <= 0xBF:
            return self.take(prefix & 0x1F).decode()
        if prefix == 0xC0:
            return None
        if prefix == 0xC2:
            return False
        if prefix == 0xC3:
            return True
        if prefix in (0xC4, 0xC5, 0xC6):
            if prefix == 0xC4:
                size = self.number(">B", 1)
            elif prefix == 0xC5:
                size = self.number(">H", 2)
            else:
                size = self.number(">I", 4)
            return {"$binary": self.take(size).hex()}
        if prefix == 0xCA:
            return self.number(">f", 4)
        if prefix == 0xCB:
            return self.number(">d", 8)
        if prefix in (0xCC, 0xCD, 0xCE, 0xCF):
            fmt, size = {
                0xCC: (">B", 1),
                0xCD: (">H", 2),
                0xCE: (">I", 4),
                0xCF: (">Q", 8),
            }[prefix]
            return self.number(fmt, size)
        if prefix in (0xD0, 0xD1, 0xD2, 0xD3):
            fmt, size = {
                0xD0: (">b", 1),
                0xD1: (">h", 2),
                0xD2: (">i", 4),
                0xD3: (">q", 8),
            }[prefix]
            return self.number(fmt, size)
        if prefix in (0xD9, 0xDA, 0xDB):
            if prefix == 0xD9:
                size = self.number(">B", 1)
            elif prefix == 0xDA:
                size = self.number(">H", 2)
            else:
                size = self.number(">I", 4)
            return self.take(size).decode()
        if prefix in (0xDC, 0xDD):
            size = self.number(">H", 2) if prefix == 0xDC else self.number(">I", 4)
            return [self.decode() for _ in range(size)]
        if prefix in (0xDE, 0xDF):
            size = self.number(">H", 2) if prefix == 0xDE else self.number(">I", 4)
            return {self.decode(): self.decode() for _ in range(size)}
        raise ValueError(f"unsupported MessagePack prefix 0x{prefix:02x}")


def date_string(value) -> str | None:
    if (
        isinstance(value, list)
        and value
        and isinstance(value[0], list)
        and len(value[0]) == 3
    ):
        year, month, day = value[0]
        return f"{year:04d}-{month:02d}-{day:02d}"
    return None


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--store", required=True)
    parser.add_argument("--date", required=True)
    args = parser.parse_args()

    decoder = Decoder(Path(args.store).read_bytes())
    payload = decoder.decode()
    records = payload[4]
    matches = []
    for record in records:
        if not isinstance(record, list) or len(record) < 33:
            continue
        status = record[3][0] if isinstance(record[3], list) else record[3]
        if status in {"done", "cancelled"}:
            continue
        date_fields = [date_string(record[index]) for index in range(12, 16)]
        if args.date not in date_fields:
            continue
        matches.append(
            {
                "id": record[0],
                "title": record[1],
                "status": status,
                "priority": record[4],
                "dateFields12To16": date_fields,
                "filePath": record[18],
                "sourceType": record[20],
                "originalLine": record[31],
                "lineNumber": record[32],
            }
        )

    print(
        json.dumps(
            {
                "version": payload[0],
                "vault": payload[3],
                "taskCount": len(records),
                "matchedCount": len(matches),
                "matches": matches,
                "decodedBytes": decoder.offset,
            },
            ensure_ascii=False,
            indent=2,
        )
    )


if __name__ == "__main__":
    main()
