#!/usr/bin/env python3
"""Build disposable inode-counter/bitmap mismatch regression images."""
import pathlib
import struct
import subprocess
import sys

image = pathlib.Path(sys.argv[1])
mode = sys.argv[2]
assert mode in ('clean', 'stale-first', 'stale-all')
with image.open('xb') as stream:
    stream.truncate(256 * 1024 * 1024)
subprocess.run([
    'mkfs.ext4', '-F', '-q', '-b', '4096', '-N', '512',
    '-O', '^64bit,^metadata_csum,^metadata_csum_seed,^orphan_file', str(image)
], check=True)
with image.open('r+b') as stream:
    stream.seek(1024)
    superblock = stream.read(1024)
    block_size = 1024 << struct.unpack_from('<I', superblock, 24)[0]
    inodes_per_group = struct.unpack_from('<I', superblock, 40)[0]
    assert block_size == 4096 and inodes_per_group == 256
    group_count = {'clean': 0, 'stale-first': 1, 'stale-all': 2}[mode]
    groups = range(group_count)
    for group in groups:
        offset = block_size + group * 32
        stream.seek(offset)
        descriptor = bytearray(stream.read(32))
        bitmap = struct.unpack_from('<I', descriptor, 4)[0]
        free_inodes = struct.unpack_from('<H', descriptor, 14)[0]
        assert free_inodes > 0
        # The mismatch is intentional. Avoid lazy bitmap initialization
        # discarding the fixture when the second group is first accessed.
        flags = struct.unpack_from('<H', descriptor, 18)[0]
        struct.pack_into('<H', descriptor, 18, flags & ~1)
        stream.seek(offset)
        stream.write(descriptor)
        stream.seek(bitmap * block_size)
        stream.write(b'\xff' * (inodes_per_group // 8))
