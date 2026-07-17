#!/usr/bin/env python3
"""Create and verify deterministic Android sparse-image v1 files."""

import argparse
import os
import pathlib
import struct


MAGIC = 0xED26FF3A
MAJOR_VERSION = 1
FILE_HEADER = struct.Struct("<IHHHHIIII")
CHUNK_HEADER = struct.Struct("<HHII")
RAW_CHUNK = 0xCAC1
DONT_CARE_CHUNK = 0xCAC3
BLOCK_SIZE = 4096
MAX_RAW_BLOCKS = (0xFFFFFFFF - CHUNK_HEADER.size) // BLOCK_SIZE
ZERO_BLOCK = bytes(BLOCK_SIZE)


def classify_blocks(path):
    size = path.stat().st_size
    if size % BLOCK_SIZE:
        raise SystemExit(f"raw image size is not {BLOCK_SIZE}-byte aligned: {size}")
    runs = []
    with path.open("rb", buffering=0) as source:
        for block_index in range(size // BLOCK_SIZE):
            block = source.read(BLOCK_SIZE)
            if len(block) != BLOCK_SIZE:
                raise SystemExit("unexpected end of raw image")
            is_raw = block != ZERO_BLOCK
            if runs and runs[-1][0] == is_raw and (
                    not is_raw or runs[-1][2] < MAX_RAW_BLOCKS):
                kind, start, count = runs[-1]
                runs[-1] = (kind, start, count + 1)
            else:
                runs.append((is_raw, block_index, 1))
    return size, runs


def encode(raw_path, sparse_path):
    size, runs = classify_blocks(raw_path)
    total_blocks = size // BLOCK_SIZE
    with raw_path.open("rb", buffering=0) as source, sparse_path.open("wb") as out:
        out.write(FILE_HEADER.pack(
            MAGIC,
            MAJOR_VERSION,
            0,
            FILE_HEADER.size,
            CHUNK_HEADER.size,
            BLOCK_SIZE,
            total_blocks,
            len(runs),
            0,
        ))
        for is_raw, start, count in runs:
            if is_raw:
                out.write(CHUNK_HEADER.pack(
                    RAW_CHUNK,
                    0,
                    count,
                    CHUNK_HEADER.size + count * BLOCK_SIZE,
                ))
                source.seek(start * BLOCK_SIZE)
                remaining = count * BLOCK_SIZE
                while remaining:
                    data = source.read(min(4 * 1024 * 1024, remaining))
                    if not data:
                        raise SystemExit("unexpected end of raw image")
                    out.write(data)
                    remaining -= len(data)
            else:
                out.write(CHUNK_HEADER.pack(
                    DONT_CARE_CHUNK,
                    0,
                    count,
                    CHUNK_HEADER.size,
                ))


def parse_header(source):
    header = source.read(FILE_HEADER.size)
    if len(header) != FILE_HEADER.size:
        raise SystemExit("truncated Android sparse-image header")
    values = FILE_HEADER.unpack(header)
    magic, major, minor, file_size, chunk_size, block_size, blocks, chunks, checksum = values
    if magic != MAGIC or major != MAJOR_VERSION or minor != 0:
        raise SystemExit("unsupported Android sparse-image version")
    if file_size != FILE_HEADER.size or chunk_size != CHUNK_HEADER.size:
        raise SystemExit("unsupported Android sparse-image header size")
    if block_size != BLOCK_SIZE or checksum != 0:
        raise SystemExit("unexpected Android sparse-image block size or checksum")
    return blocks, chunks


def expand(sparse_path, raw_path):
    with sparse_path.open("rb", buffering=0) as source, raw_path.open("wb") as out:
        total_blocks, total_chunks = parse_header(source)
        emitted_blocks = 0
        for _ in range(total_chunks):
            header = source.read(CHUNK_HEADER.size)
            if len(header) != CHUNK_HEADER.size:
                raise SystemExit("truncated Android sparse-image chunk header")
            kind, reserved, blocks, total_size = CHUNK_HEADER.unpack(header)
            if reserved != 0:
                raise SystemExit("non-zero Android sparse-image reserved field")
            if kind == RAW_CHUNK:
                expected = CHUNK_HEADER.size + blocks * BLOCK_SIZE
                if total_size != expected:
                    raise SystemExit("invalid Android sparse raw chunk size")
                remaining = blocks * BLOCK_SIZE
                while remaining:
                    data = source.read(min(4 * 1024 * 1024, remaining))
                    if not data:
                        raise SystemExit("truncated Android sparse raw chunk")
                    out.write(data)
                    remaining -= len(data)
            elif kind == DONT_CARE_CHUNK:
                if total_size != CHUNK_HEADER.size:
                    raise SystemExit("invalid Android sparse don't-care chunk size")
                out.seek(blocks * BLOCK_SIZE, os.SEEK_CUR)
            else:
                raise SystemExit(f"unsupported Android sparse chunk: 0x{kind:04x}")
            emitted_blocks += blocks
        if emitted_blocks != total_blocks or source.read(1):
            raise SystemExit("Android sparse-image block count or trailing data mismatch")
        out.truncate(total_blocks * BLOCK_SIZE)


def main():
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="operation", required=True)
    for operation in ("encode", "expand"):
        subparser = subparsers.add_parser(operation)
        subparser.add_argument("source", type=pathlib.Path)
        subparser.add_argument("destination", type=pathlib.Path)
    args = parser.parse_args()
    if args.operation == "encode":
        encode(args.source, args.destination)
    else:
        expand(args.source, args.destination)


if __name__ == "__main__":
    main()
