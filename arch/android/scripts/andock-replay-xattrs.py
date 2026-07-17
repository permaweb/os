#!/usr/bin/env python3
import argparse
import os
import pathlib
import subprocess


def debugfs_quote(value):
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("root", type=pathlib.Path)
    parser.add_argument("image", type=pathlib.Path)
    parser.add_argument("work", type=pathlib.Path)
    args = parser.parse_args()

    root = args.root.resolve()
    args.work.mkdir(parents=True, exist_ok=True)
    commands = []
    count = 0
    seen_inodes = set()
    paths = [root]
    paths.extend(sorted(
        root.rglob("*"), key=lambda path: path.relative_to(root).as_posix()
    ))
    for path in paths:
        info = path.lstat()
        inode = (info.st_dev, info.st_ino)
        if info.st_nlink > 1:
            if inode in seen_inodes:
                continue
            seen_inodes.add(inode)
        relative = path.relative_to(root).as_posix()
        guest_path = "/" + relative
        for name in sorted(os.listxattr(path, follow_symlinks=False)):
            value_path = args.work / f"{count:08d}.xattr"
            value_path.write_bytes(
                os.getxattr(path, name, follow_symlinks=False)
            )
            commands.append(
                "ea_set -f "
                + debugfs_quote(str(value_path))
                + " "
                + debugfs_quote(guest_path)
                + " "
                + debugfs_quote(name)
            )
            count += 1

    command_file = args.work / "debugfs.commands"
    command_file.write_text("\n".join(commands) + ("\n" if commands else ""))
    if commands:
        subprocess.run(
            ["debugfs", "-w", "-f", str(command_file), str(args.image)],
            check=True,
        )
    print(f"replayed-xattrs={count}")


if __name__ == "__main__":
    main()
