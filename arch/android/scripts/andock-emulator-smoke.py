#!/usr/bin/env python3

import argparse
import base64
import json
import subprocess
import struct
import threading
import time


PACKAGE = "org.permaweb.andee"
SOCKET = f"/data/user/0/{PACKAGE}/no_backup/run/andee-execution.sock"
PROTOCOL = "andock-local@1"
MAX_OUTPUT = 20 * 1024 * 1024


class Client:
    def __init__(self, adb, serial):
        self.adb = adb
        self.serial = serial

    def adb_command(self, *arguments, timeout=60):
        return subprocess.run(
            [self.adb, "-s", self.serial, *arguments],
            check=True,
            capture_output=True,
            timeout=timeout,
        )

    def request(self, action, member, **fields):
        payload = json.dumps({
            "protocol": PROTOCOL,
            "action": action,
            "member-id": member,
            **fields,
        }, separators=(",", ":")).encode()
        process = subprocess.Popen(
            [
                self.adb, "-s", self.serial, "shell", "run-as", PACKAGE,
                "toybox", "nc", "-W", "60", "-U", SOCKET,
            ],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        output, error = process.communicate(
            struct.pack(">I", len(payload)) + payload,
            timeout=70,
        )
        if process.returncode != 0:
            raise RuntimeError(error.decode(errors="replace"))
        if len(output) < 4:
            raise RuntimeError("Andock response has no frame header")
        length = struct.unpack(">I", output[:4])[0]
        if len(output) != length + 4:
            raise RuntimeError("Andock response frame is truncated")
        return json.loads(output[4:])

    def wait_until_ready(self):
        deadline = time.monotonic() + 60
        last_error = None
        while time.monotonic() < deadline:
            try:
                response = self.request(
                    "exec",
                    "smoke-ready",
                    cwd="/root",
                    command="printf ready",
                    **{"timeout-ms": 10_000, "allow-network": False},
                )
                if response.get("status") == 200:
                    return
            except Exception as failure:
                last_error = failure
            time.sleep(0.5)
        raise RuntimeError(f"Andock service did not become ready: {last_error}")


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def decode_output(response):
    encoded = response["body"]["output"]
    return base64.urlsafe_b64decode(encoded + "=" * (-len(encoded) % 4))


def success(response):
    require(response.get("ok") is True, response)
    require(response.get("status") == 200, response)
    return response["body"]


def exec_command(client, member, command, timeout=30_000):
    response = client.request(
        "exec",
        member,
        cwd="/root",
        command=command,
        **{"timeout-ms": timeout, "allow-network": False},
    )
    success(response)
    return response


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
    cancellable = "smoke-cancel"
    unusual_name = "odd\tline\nfile.bin"
    content = bytes(range(256)) * (3 * 1024 * 1024 // 256)
    try:
        environment = exec_command(
            client,
            member,
            "pwd; id; python3 --version; node --version; "
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
        for cleanup in (member, sibling, cancellable, "smoke-ready"):
            try:
                client.request("destroy", cleanup)
            except Exception:
                pass
    print("ANDOCK_EMULATOR_SMOKE_OK")


if __name__ == "__main__":
    main()
