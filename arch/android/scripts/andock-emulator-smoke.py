#!/usr/bin/env python3

import argparse
import base64
import threading
import time

from andock_emulator_client import (
    PACKAGE,
    Client,
    decode_output,
    exec_command,
    require,
    success,
)

MAX_OUTPUT = 50 * 1024 * 1024


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--adb", default="adb")
    parser.add_argument("--serial", required=True)
    arguments = parser.parse_args()
    client = Client(arguments.adb, arguments.serial)

    architecture = client.adb_command("shell", "getprop", "ro.product.cpu.abi").stdout
    require(architecture.strip() == b"arm64-v8a", architecture)
    enforcing = client.adb_command("shell", "getenforce").stdout
    require(enforcing.strip() == b"Enforcing", enforcing)
    client.wait_until_ready()

    member = "smoke-primary"
    sibling = "smoke-sibling"
    # Reuse the sibling image after its isolation/session-ownership checks so
    # the workload remains valid on the emulator's deliberately small data
    # partition without weakening the distinct-member assertions.
    cancellable = sibling
    session_member = sibling
    session_run = f"{time.time_ns():x}"
    unusual_name = "odd\tline\nfile.bin"
    content = bytes(range(256)) * (3 * 1024 * 1024 // 256)
    try:
        invalid_protocol = client.request(
            "read",
            member,
            protocol="not-andock",
            path="/root/missing",
        )
        require(invalid_protocol.get("status") == 400, invalid_protocol)
        invalid_member = client.request("list", "../member", path="/root")
        require(invalid_member.get("status") == 400, invalid_member)
        traversal = client.request("read", member, path="/root/../etc/passwd")
        require(traversal.get("status") == 400, traversal)
        unknown = client.request("unknown", member)
        require(unknown.get("status") == 404, unknown)

        environment = exec_command(
            client,
            member,
            "pwd; id; test -x /usr/bin/true; /usr/bin/true; "
            "python3 --version; node --version; "
            "printf x >/dev/null; "
            "test \"$(dd if=/dev/zero bs=4 count=1 2>/dev/null | od -An -tx1)\" "
            "= \" 00 00 00 00\"; head -c 16 /dev/urandom | wc -c; "
            "printf shm >/dev/shm/andock-smoke; "
            "test \"$(cat /dev/shm/andock-smoke)\" = shm",
        )
        environment_output = decode_output(environment)
        require(environment["body"]["exit-code"] == 0, environment_output)
        require(b"/root\nuid=0(root)" in environment_output, environment_output)
        require(b"Python 3.12" in environment_output, environment_output)
        require(b"v22." in environment_output, environment_output)

        independent_offsets = exec_command(
            client,
            member,
            "python3 - <<'PY'\n"
            "path = '/root/independent-offsets'\n"
            "open(path, 'wb').write(b'abcdef')\n"
            "with open(path, 'rb') as first, open(path, 'rb') as second:\n"
            "    first.seek(3)\n"
            "    assert second.tell() == 0\n"
            "    assert first.read(1) == b'd'\n"
            "    assert second.read(1) == b'a'\n"
            "PY",
        )
        require(
            independent_offsets["body"]["exit-code"] == 0,
            decode_output(independent_offsets),
        )
        shared_offset = exec_command(
            client,
            member,
            "python3 - <<'PY'\n"
            "import concurrent.futures\n"
            "import os\n"
            "path = '/root/shared-offset'\n"
            "expected = [f'{index:063x}\\n'.encode() for index in range(4096)]\n"
            "open(path, 'wb').write(b''.join(expected))\n"
            "descriptor = os.open(path, os.O_RDONLY)\n"
            "def drain():\n"
            "    records = []\n"
            "    while True:\n"
            "        record = os.read(descriptor, 64)\n"
            "        if not record:\n"
            "            return records\n"
            "        assert len(record) == 64\n"
            "        records.append(record)\n"
            "with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:\n"
            "    records = sum((task.result() for task in "
            "[pool.submit(drain) for _ in range(8)]), [])\n"
            "os.close(descriptor)\n"
            "assert sorted(records) == expected\n"
            "PY",
        )
        require(
            shared_offset["body"]["exit-code"] == 0,
            decode_output(shared_offset),
        )
        concurrent_directories = exec_command(
            client,
            member,
            "python3 - <<'PY'\n"
            "import concurrent.futures\n"
            "import os\n"
            "path = '/root/concurrent-directories'\n"
            "os.makedirs(path, exist_ok=True)\n"
            "expected = {f'entry-{index:03d}' for index in range(64)}\n"
            "for name in expected:\n"
            "    open(os.path.join(path, name), 'wb').close()\n"
            "def scan(_):\n"
            "    for _ in range(200):\n"
            "        assert set(os.listdir(path)) == expected\n"
            "with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:\n"
            "    list(pool.map(scan, range(8)))\n"
            "PY",
            timeout=120_000,
        )
        require(
            concurrent_directories["body"]["exit-code"] == 0,
            decode_output(concurrent_directories),
        )
        missing_path = client.request("read", member, path="/root/missing")
        require(missing_path.get("status") == 404, missing_path)
        directory_read = client.request("read", member, path="/root")
        require(directory_read.get("status") == 400, directory_read)

        encoded = base64.urlsafe_b64encode(content).decode().rstrip("=")
        success(client.request(
            "write",
            member,
            path=f"/root/{unusual_name}",
            content=encoded,
        ))
        read = success(client.request(
            "read",
            member,
            path=f"/root/{unusual_name}",
        ))
        require(read["content"] == encoded, "multi-megabyte file changed")
        entries = success(client.request("list", member, path="/root"))["entries"]
        require(unusual_name in {entry["name"] for entry in entries}, entries)

        missing = client.request(
            "read",
            sibling,
            path=f"/root/{unusual_name}",
        )
        require(missing.get("status") == 404, missing)

        atomic = exec_command(
            client,
            member,
            "printf old > target; printf new > replacement; "
            "mv replacement target; test \"$(cat target)\" = new; "
            "ln target hardlink; chmod 0600 target; test target -ef hardlink",
        )
        require(atomic["body"]["exit-code"] == 0, decode_output(atomic))

        clipped = exec_command(
            client,
            member,
            f"head -c {MAX_OUTPUT + 1} /dev/zero",
        )
        require(clipped["body"]["output-truncated"] is True, clipped)
        require(len(decode_output(clipped)) == MAX_OUTPUT, "wrong clipping boundary")

        timed = exec_command(client, member, "sleep 10", timeout=300)
        require(timed["body"]["timed-out"] is True, timed)
        require(timed["body"]["exit-code"] == 124, timed)

        session_id = f"smokesession{session_run}"
        started = success(client.request(
            "session-start",
            session_member,
            **{
                "session-id": session_id,
                "cwd": "/root",
                "command": "printf ready; sleep 5; printf done",
                "timeout-ms": None,
                "wait-ms": 100,
                "allow-network": False,
            },
        ))
        require(started["session-id"] == session_id, started)
        conflict_started = time.monotonic()
        active_bash_conflict = client.request(
            "exec",
            session_member,
            **{
                "cwd": "/root",
                "command": "printf conflict",
                "timeout-ms": 30_000,
                "allow-network": False,
            },
        )
        active_bash_elapsed = time.monotonic() - conflict_started
        require(active_bash_conflict.get("status") == 409, active_bash_conflict)
        require(active_bash_conflict.get("error") == "member-session-active", active_bash_conflict)
        require(active_bash_conflict.get("session-id") == session_id, active_bash_conflict)
        require(active_bash_conflict.get("execution-status") == "running", active_bash_conflict)
        require(active_bash_conflict.get("session-control-action") == "bash-session", active_bash_conflict)
        require(
            active_bash_conflict.get("session-control-operations")
            == ["poll", "wait", "terminate"],
            active_bash_conflict,
        )
        require(active_bash_elapsed < 3, active_bash_elapsed)
        read_conflict_started = time.monotonic()
        active_read_conflict = client.request(
            "read",
            session_member,
            path="/root/conflicting-read",
        )
        active_read_elapsed = time.monotonic() - read_conflict_started
        require(active_read_conflict.get("status") == 409, active_read_conflict)
        require(active_read_conflict.get("error") == "member-session-active", active_read_conflict)
        require(active_read_conflict.get("session-id") == session_id, active_read_conflict)
        require(active_read_elapsed < 3, active_read_elapsed)
        still_running = success(client.request(
            "session-poll",
            session_member,
            **{
                "session-id": session_id,
                "cursor": 0,
                "wait-ms": 0,
                "terminate": False,
            },
        ))
        require(still_running["execution-status"] == "running", still_running)
        replay = success(client.request(
            "session-start",
            session_member,
            **{
                "session-id": session_id,
                "cwd": "/root",
                "command": "printf ready; sleep 5; printf done",
                "timeout-ms": None,
                "wait-ms": 0,
                "allow-network": False,
            },
        ))
        require(replay["session-id"] == session_id, replay)
        conflict = client.request(
            "session-start",
            session_member,
            **{
                "session-id": session_id,
                "cwd": "/root",
                "command": "printf different",
                "timeout-ms": None,
                "wait-ms": 0,
                "allow-network": False,
            },
        )
        require(conflict.get("status") == 409, conflict)
        encoded_output = started["output"]
        collected = bytearray(base64.urlsafe_b64decode(
            encoded_output + "=" * (-len(encoded_output) % 4),
        ))
        cursor = started["next-cursor"]
        terminal = started if started["execution-status"] != "running" else None
        for _ in range(40):
            if terminal is not None:
                break
            polled = success(client.request(
                "session-poll",
                session_member,
                **{
                    "session-id": session_id,
                    "cursor": cursor,
                    "wait-ms": 200,
                    "terminate": False,
                },
            ))
            encoded_output = polled["output"]
            collected.extend(base64.urlsafe_b64decode(
                encoded_output + "=" * (-len(encoded_output) % 4),
            ))
            cursor = polled["next-cursor"]
            if polled["execution-status"] != "running":
                terminal = polled
                break
        require(
            bytes(collected) == b"readydone",
            {"collected": bytes(collected), "started": started, "terminal": terminal},
        )
        require(terminal is not None, "session never became terminal")
        require(terminal["execution-status"] == "exited", terminal)
        require(terminal["exit-code"] == 0, terminal)
        foreign = client.request(
            "session-poll",
            member,
            **{
                "session-id": session_id,
                "cursor": 0,
                "wait-ms": 0,
                "terminate": False,
            },
        )
        require(foreign.get("status") == 404, foreign)

        terminate_id = f"smoketerminate{session_run}"
        success(client.request(
            "session-start",
            session_member,
            **{
                "session-id": terminate_id,
                "cwd": "/root",
                "command": "printf running; sleep 30",
                "timeout-ms": None,
                "wait-ms": 100,
                "allow-network": False,
            },
        ))
        terminate_conflict = client.request(
            "exec",
            session_member,
            **{
                "cwd": "/root",
                "command": "printf must-not-run",
                "timeout-ms": 30_000,
                "allow-network": False,
            },
        )
        require(terminate_conflict.get("status") == 409, terminate_conflict)
        require(terminate_conflict.get("session-id") == terminate_id, terminate_conflict)
        terminated = success(client.request(
            "session-poll",
            session_member,
            **{
                "session-id": terminate_id,
                "cursor": 0,
                "wait-ms": 1000,
                "terminate": True,
            },
        ))
        require(terminated["execution-status"] == "terminated", terminated)
        require(terminated["exit-code"] == 143, terminated)

        natural_id = f"smokenatural{session_run}"
        natural = success(client.request(
            "session-start",
            session_member,
            **{
                "session-id": natural_id,
                "cwd": "/root",
                "command": "exit 124",
                "timeout-ms": None,
                "wait-ms": 1000,
                "allow-network": False,
            },
        ))
        require(natural["execution-status"] == "exited", natural)
        require(natural["exit-code"] == 124, natural)

        timeout_id = f"smoketimeout{session_run}"
        expired = success(client.request(
            "session-start",
            session_member,
            **{
                "session-id": timeout_id,
                "cwd": "/root",
                "command": "sleep 30",
                "timeout-ms": 300,
                "wait-ms": 1000,
                "allow-network": False,
            },
        ))
        require(expired["execution-status"] == "timed-out", expired)
        require(expired["exit-code"] == 124, expired)

        archive = exec_command(
            client,
            member,
            "set -eu; rm -rf /root/tar-source /root/tar-target "
            "/root/tar-test.tar; mkdir /root/tar-source; "
            "printf archive >/root/tar-source/file; "
            "chmod 0640 /root/tar-source/file; "
            "chmod 0751 /root/tar-source; "
            "touch -d @1700000000 /root/tar-source/file /root/tar-source; "
            "tar -C /root -cf /root/tar-test.tar tar-source; "
            "mkdir /root/tar-target; "
            "tar -C /root/tar-target -xf /root/tar-test.tar; "
            "test \"$(stat -c %a /root/tar-target/tar-source)\" = 751; "
            "test \"$(stat -c %a /root/tar-target/tar-source/file)\" = 640; "
            "test \"$(stat -c %Y /root/tar-target/tar-source/file)\" "
            "= 1700000000; "
            "test \"$(cat /root/tar-target/tar-source/file)\" = archive",
        )
        require(archive["body"]["exit-code"] == 0, archive)

        fchmodat2 = exec_command(
            client,
            member,
            "python3 - <<'PY'\n"
            "import ctypes\n"
            "import os\n"
            "path = b'/root/fchmodat2-file'\n"
            "open(path, 'wb').close()\n"
            "libc = ctypes.CDLL(None, use_errno=True)\n"
            "AT_FDCWD = -100\n"
            "AT_EMPTY_PATH = 0x1000\n"
            "assert libc.syscall(452, AT_FDCWD, path, 0o640, "
            "AT_EMPTY_PATH) == 0, ctypes.get_errno()\n"
            "descriptor = os.open(path, os.O_RDONLY)\n"
            "try:\n"
            "    assert libc.syscall(452, descriptor, b'', 0o600, "
            "AT_EMPTY_PATH) == 0, ctypes.get_errno()\n"
            "finally:\n"
            "    os.close(descriptor)\n"
            "assert os.stat(path).st_mode & 0o7777 == 0o600\n"
            "PY",
        )
        require(fchmodat2["body"]["exit-code"] == 0, fchmodat2)

        result = {}

        def run_cancellable():
            try:
                result["exec"] = exec_command(
                    client,
                    cancellable,
                    "sleep 30",
                    timeout=30_000,
                )
            except Exception as failure:
                result["failure"] = failure

        thread = threading.Thread(target=run_cancellable)
        thread.start()
        time.sleep(0.5)
        success(client.request("stop", cancellable))
        thread.join(10)
        require(not thread.is_alive(), "cancelled command did not return")
        require("failure" not in result, result.get("failure"))
        require("exec" in result, "cancelled command returned no response")
        require(result["exec"]["body"]["cancelled"] is True, result)
        require(result["exec"]["body"]["exit-code"] == 130, result)

        denied = exec_command(
            client,
            member,
            "bash -c 'exec 3<>/dev/tcp/1.1.1.1/80'",
        )
        require(denied["body"]["exit-code"] != 0, denied)
        require(b"Permission denied" in decode_output(denied), denied)

        isolation = exec_command(
            client,
            member,
            "test -d /proc; "
            "mountpoint -q /proc; "
            "test \"$(stat -f -c %t /proc)\" = 9fa0; "
            "test \"$(readlink /proc/self/root)\" = /; "
            "test \"$(readlink /proc/self/cwd)\" = /root; "
            "test \"$(readlink /proc/self/exe)\" = /usr/bin/bash; "
            "fds=$(find /proc/self/fd -mindepth 1 -maxdepth 1 "
            "-printf '%f\\n' | sort -n | tr '\\n' ' '); "
            "case \"$fds\" in '0 1 2 '*) ;; *) exit 1;; esac; "
            "for descriptor in /proc/self/fd/*; do "
            "case \"$(readlink \"$descriptor\")\" in "
            "*/data/*|*org.permaweb.andee*|*execution-state*|*andock.image*) "
            "exit 1;; esac; done; "
            "test ! -r /data/user/0/org.permaweb.andee; "
            "test ! -r /data/data/org.permaweb.andee; "
            "test ! -e /proc/self/root/data/user/0/org.permaweb.andee",
        )
        require(isolation["body"]["exit-code"] == 0, decode_output(isolation))

        client.adb_command("shell", "am", "force-stop", PACKAGE)
        client.adb_command(
            "shell", "am", "start", "-W", "-n", f"{PACKAGE}/.OrnamentActivity",
        )
        client.wait_until_ready()
        persisted = success(client.request(
            "read",
            member,
            path=f"/root/{unusual_name}",
        ))
        require(persisted["content"] == encoded, "restart lost member state")

        success(client.request("destroy", member))
        destroyed = client.request(
            "read",
            member,
            path=f"/root/{unusual_name}",
        )
        require(destroyed.get("status") == 404, destroyed)
    finally:
        for cleanup in (member, sibling, cancellable, session_member):
            try:
                client.request("destroy", cleanup)
            except Exception:
                pass
    print("ANDOCK_EMULATOR_SMOKE_OK")


if __name__ == "__main__":
    main()
