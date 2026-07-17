import base64
import json
import math
import struct
import subprocess
import time


PACKAGE = "org.permaweb.andee"
SOCKET = f"/data/user/0/{PACKAGE}/no_backup/run/andee-execution.sock"
PROTOCOL = "andock-local@1"


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
        command_timeout_ms = fields.get("timeout-ms", 0)
        socket_timeout = max(60, math.ceil(command_timeout_ms / 1000) + 15)
        process = subprocess.Popen(
            [
                self.adb, "-s", self.serial, "shell", "run-as", PACKAGE,
                "toybox", "nc", "-W", str(socket_timeout), "-U", SOCKET,
            ],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        output, error = process.communicate(
            struct.pack(">I", len(payload)) + payload,
            timeout=socket_timeout + 10,
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


def exec_command(
    client,
    member,
    command,
    timeout=30_000,
    allow_network=False,
    cwd="/root",
):
    response = client.request(
        "exec",
        member,
        cwd=cwd,
        command=command,
        **{"timeout-ms": timeout, "allow-network": allow_network},
    )
    success(response)
    return response
