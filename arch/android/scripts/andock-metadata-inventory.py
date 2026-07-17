#!/usr/bin/env python3
import argparse
import base64
import collections
import errno
import hashlib
import json
import os
import pathlib
import stat


REPRESENTATIVE_PATHS = (
    "bin",
    "etc/os-release",
    "etc/shadow",
    "usr/bin/passwd",
    "usr/bin/python3.12",
    "usr/local/bin/node",
    "var/cache/apt/archives/partial",
)


def file_sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def xattrs(path):
    try:
        names = os.listxattr(path, follow_symlinks=False)
    except OSError as error:
        if error.errno in (errno.ENOTSUP, errno.EOPNOTSUPP):
            return {}
        raise
    return {
        name: base64.b64encode(
            os.getxattr(path, name, follow_symlinks=False)
        ).decode("ascii")
        for name in sorted(names)
    }


def entry_type(mode):
    if stat.S_ISREG(mode):
        return "file"
    if stat.S_ISDIR(mode):
        return "directory"
    if stat.S_ISLNK(mode):
        return "symlink"
    if stat.S_ISCHR(mode):
        return "character-device"
    if stat.S_ISBLK(mode):
        return "block-device"
    if stat.S_ISFIFO(mode):
        return "fifo"
    if stat.S_ISSOCK(mode):
        return "socket"
    return "unknown"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("root", type=pathlib.Path)
    parser.add_argument("inventory", type=pathlib.Path)
    parser.add_argument("summary", type=pathlib.Path)
    parser.add_argument("--source-date-epoch", required=True, type=int)
    parser.add_argument("--exclude-top", action="append", default=[])
    args = parser.parse_args()

    root = args.root.resolve()
    excluded = set(args.exclude_top)
    paths = [root]
    paths.extend(
        path
        for path in root.rglob("*")
        if path.relative_to(root).parts[0] not in excluded
    )
    paths.sort(key=lambda path: path.relative_to(root).as_posix())
    metadata = [(path, path.lstat()) for path in paths]

    inode_paths = collections.defaultdict(list)
    for path, info in metadata:
        if stat.S_ISREG(info.st_mode) and info.st_nlink > 1:
            inode_paths[(info.st_dev, info.st_ino)].append(
                path.relative_to(root).as_posix()
            )
    hardlink_first = {}
    hardlink_groups = []
    for members in inode_paths.values():
        members.sort()
        hardlink_groups.append(members)
        for member in members:
            hardlink_first[member] = members[0]
    hardlink_groups.sort()

    counts = collections.Counter()
    owners = collections.Counter()
    xattr_paths = []
    capability_paths = []
    representatives = {}
    fixed_mtime_violations = []
    args.inventory.parent.mkdir(parents=True, exist_ok=True)
    inventory_digest = hashlib.sha256()

    with args.inventory.open("wb") as output:
        for path, info in metadata:
            relative = path.relative_to(root).as_posix() or "."
            kind = entry_type(info.st_mode)
            attributes = xattrs(path)
            record = {
                "gid": info.st_gid,
                "mode": f"{stat.S_IMODE(info.st_mode):04o}",
                "mtime-ns": info.st_mtime_ns,
                "path": relative,
                "type": kind,
                "uid": info.st_uid,
                "xattrs": attributes,
            }
            if kind == "file":
                record["sha256"] = file_sha256(path)
                record["size"] = info.st_size
                if relative in hardlink_first:
                    record["hardlink-to"] = hardlink_first[relative]
            elif kind == "symlink":
                record["target"] = os.readlink(path)
            elif kind in ("character-device", "block-device"):
                record["device"] = info.st_rdev

            encoded = (
                json.dumps(record, sort_keys=True, separators=(",", ":")) + "\n"
            ).encode()
            output.write(encoded)
            inventory_digest.update(encoded)
            counts[kind] += 1
            owners[f"{info.st_uid}:{info.st_gid}"] += 1
            if attributes:
                xattr_paths.append(relative)
            if "security.capability" in attributes:
                capability_paths.append(relative)
            if info.st_mtime_ns != args.source_date_epoch * 1_000_000_000:
                fixed_mtime_violations.append(relative)
            if relative in REPRESENTATIVE_PATHS:
                representatives[relative] = record

    summary = {
        "capability-paths": capability_paths,
        "counts": dict(sorted(counts.items())),
        "fixed-mtime-violations": fixed_mtime_violations,
        "hardlink-groups": hardlink_groups,
        "inventory-sha256": inventory_digest.hexdigest(),
        "owners": dict(sorted(owners.items())),
        "representatives": representatives,
        "total-entries": len(metadata),
        "xattr-paths": xattr_paths,
    }
    args.summary.parent.mkdir(parents=True, exist_ok=True)
    args.summary.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n")


if __name__ == "__main__":
    main()
