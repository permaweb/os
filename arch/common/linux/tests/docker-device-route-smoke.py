#!/usr/bin/env python3
"""Exercise docker@1.0 through the public HyperBEAM route inside LapEE."""

import argparse
import json
import pathlib
import re
import time
import urllib.error
import urllib.request


TOOLS = ["Read", "Write", "Append", "Edit", "Glob", "Grep", "Bash"]
MEMBER = "docker-contract-probe"
OTHER_MEMBER = "docker-contract-other-member"
PARITY_MEMBER = "neutral-contract-probe"
NETWORK_MEMBER = "docker-contract-network-enabled"
NETWORK_LOCK_MEMBER = "docker-contract-network-immutable"


def request(base_url, action, body=None, *, member=MEMBER, allow_network=None,
            tools=TOOLS, method="POST", timeout=90):
    url = f"{base_url}/~docker@1.0/{action}"
    data = None
    headers = {
        "accept": "application/json",
        "accept-bundle": "true",
        "require-codec": "application/json",
    }
    if body is not None:
        metadata = {}
        if allow_network is not None:
            metadata["allow-network"] = allow_network
        message = {
            "body": {"member-id": member, **body},
            "member-context": {
                "id": member,
                "tools": tools,
                "metadata": metadata,
            },
            "require-codec": "application/json",
        }
        data = json.dumps(message, separators=(",", ":")).encode()
        headers["content-type"] = "application/json"
    try:
        with urllib.request.urlopen(
            urllib.request.Request(url, data=data, headers=headers, method=method),
            timeout=timeout,
        ) as response:
            status = response.status
            payload = response.read()
    except urllib.error.HTTPError as failure:
        status = failure.code
        payload = failure.read()
    try:
        return decode_json_payload(payload)
    except json.JSONDecodeError as error:
        raise AssertionError(
            f"{method} {url} returned HTTP {status} with non-JSON body: "
            f"{payload[:4096]!r}"
        ) from error


def decode_json_payload(payload):
    try:
        return json.loads(payload)
    except json.JSONDecodeError as direct_error:
        try:
            headers, encoded = payload.split(b"\r\n\r\n", 1)
            if b"transfer-encoding: chunked" not in headers.lower():
                raise ValueError("not a chunked HyperBEAM response")
            chunks = []
            while True:
                size_line, encoded = encoded.split(b"\r\n", 1)
                size = int(size_line.split(b";", 1)[0], 16)
                if size == 0:
                    break
                if len(encoded) < size + 2 or encoded[size:size + 2] != b"\r\n":
                    raise ValueError("invalid chunk framing")
                chunks.append(encoded[:size])
                encoded = encoded[size + 2:]
            return json.loads(b"".join(chunks))
        except (ValueError, IndexError) as envelope_error:
            raise direct_error from envelope_error


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def successful(response):
    require(response.get("status") == 200, response)
    require(response.get("ok") in (True, "true"), response)
    require(response.get("device") == "docker@1.0", response)
    return response


def run_bash(base_url, command, execution_id, *, member=MEMBER,
             allow_network=None, yield_ms=30000, timeout_ms=30000):
    return request(
        base_url,
        "bash",
        {
            "command": command,
            "cwd": "/root",
            "yield-ms": yield_ms,
            "timeout-ms": timeout_ms,
            "execution-id": execution_id,
        },
        member=member,
        allow_network=allow_network,
        timeout=max(90, timeout_ms // 1000 + 30),
    )


def collect_session(base_url, started, *, member=MEMBER, timeout=45):
    output = started.get("output", "")
    cursor = started.get("next-cursor", 0)
    polls = []
    current = started
    deadline = time.monotonic() + timeout
    while current.get("execution-status") == "running" and time.monotonic() < deadline:
        current = successful(request(
            base_url,
            "bash-session",
            {
                "session-id": started["session-id"],
                "cursor": cursor,
                "wait-ms": 200,
                "terminate": False,
            },
            member=member,
        ))
        polls.append(current)
        output += current.get("output", "")
        cursor = current.get("next-cursor", cursor)
    require(current.get("execution-status") != "running", polls)
    return output, current, polls


def cross_backend_contract(base_url):
    successful(run_bash(
        base_url,
        "rm -rf -- /root/parity",
        f"parity-clean-{time.time_ns()}",
        member=PARITY_MEMBER,
        yield_ms=5000,
    ))
    result = {}
    result["write"] = successful(request(
        base_url,
        "write",
        {"path": "parity/a.txt", "content": "alpha"},
        member=PARITY_MEMBER,
    ))
    result["append"] = successful(request(
        base_url,
        "append",
        {"path": "parity/a.txt", "content": "beta"},
        member=PARITY_MEMBER,
    ))
    result["edit"] = successful(request(
        base_url,
        "edit",
        {
            "path": "parity/a.txt",
            "old-string": "beta",
            "new-string": "gamma",
        },
        member=PARITY_MEMBER,
    ))
    result["read"] = successful(request(
        base_url, "read", {"path": "parity/a.txt"}, member=PARITY_MEMBER
    ))
    result["glob"] = successful(request(
        base_url,
        "glob",
        {"pattern": "missing-*.txt", "cwd": "/root/parity"},
        member=PARITY_MEMBER,
    ))
    result["grep"] = successful(request(
        base_url,
        "grep",
        {"pattern": "definitely-not-present", "cwd": "/root/parity"},
        member=PARITY_MEMBER,
    ))
    result["bash"] = successful(run_bash(
        base_url,
        "printf contract-ok",
        f"parity-bash-{time.time_ns()}",
        member=PARITY_MEMBER,
        yield_ms=5000,
    ))
    result["missing"] = request(
        base_url,
        "read",
        {"path": "parity/missing.txt"},
        member=PARITY_MEMBER,
    )
    result["unauthorized"] = request(
        base_url,
        "bash",
        {"command": "printf denied"},
        member=PARITY_MEMBER,
        tools=["Read"],
    )
    result["list-files"] = successful(request(
        base_url,
        "list-files",
        {"path": "/root/parity"},
        member=PARITY_MEMBER,
    ))
    started = successful(run_bash(
        base_url,
        "printf one; sleep 1; printf two",
        f"parity-session-{time.time_ns()}",
        member=PARITY_MEMBER,
        yield_ms=50,
    ))
    output, terminal, polls = collect_session(
        base_url, started, member=PARITY_MEMBER
    )
    result["session"] = {
        "output": output,
        "terminal": terminal,
        "polls": len(polls),
    }
    terminate_started = successful(run_bash(
        base_url,
        "sleep 30",
        f"parity-terminate-{time.time_ns()}",
        member=PARITY_MEMBER,
        yield_ms=50,
    ))
    result["terminated-session"] = successful(request(
        base_url,
        "bash-session",
        {
            "session-id": terminate_started["session-id"],
            "cursor": terminate_started.get("next-cursor", 0),
            "wait-ms": 5000,
            "terminate": True,
        },
        member=PARITY_MEMBER,
    ))
    result["timeout"] = request(
        base_url,
        "bash",
        {
            "command": "sleep 2",
            "yield-ms": 5000,
            "timeout-ms": 100,
            "execution-id": f"parity-timeout-{time.time_ns()}",
        },
        member=PARITY_MEMBER,
    )
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-url", required=True)
    parser.add_argument("--network-url", required=True)
    parser.add_argument("--evidence", type=pathlib.Path, required=True)
    args = parser.parse_args()
    base_url = args.base_url.rstrip("/")
    evidence = {}

    index = request(base_url, "index", method="GET")
    require(index.get("device") == "docker@1.0", index)
    require(index.get("status") == 200, index)
    require(index.get("readiness") == "ready", index)
    require(index.get("image") == "permawebos-docker-fixture:1.0", index)
    require(index.get("image-id", "").startswith("sha256:"), index)
    require(index.get("network-default") == "disabled", index)
    require(index.get("volume") == "ephemeral", index)
    evidence["index"] = index

    root = "/root/docker-contract-probe"
    route_file = f"{root}/route.txt"
    successful(run_bash(
        base_url,
        f"rm -rf -- {root}; mkdir -p -- {root}",
        "docker-contract-clean-start",
    ))
    evidence["write"] = successful(request(
        base_url, "write", {"path": route_file, "content": "alpha"}
    ))
    evidence["append"] = successful(request(
        base_url, "append", {"path": route_file, "content": "beta"}
    ))
    evidence["edit"] = successful(request(
        base_url,
        "edit",
        {"path": route_file, "old-string": "beta", "new-string": "gamma"},
    ))
    evidence["read"] = successful(request(
        base_url, "read", {"path": route_file}
    ))
    require(evidence["read"].get("content") == "alphagamma", evidence["read"])
    evidence["glob"] = successful(request(
        base_url, "glob", {"pattern": "*.txt", "cwd": root}
    ))
    require(evidence["glob"].get("output") == "route.txt\n", evidence["glob"])
    evidence["grep"] = successful(request(
        base_url, "grep", {"pattern": "gamma", "cwd": root}
    ))
    require("gamma" in evidence["grep"].get("output", ""), evidence["grep"])

    bash = successful(run_bash(
        base_url, "printf shell-ok", "docker-contract-bash", yield_ms=5000
    ))
    bash_output, bash_terminal, bash_polls = collect_session(base_url, bash)
    require(bash_terminal.get("execution-status") == "exited", bash_terminal)
    require(bash_output == "shell-ok", bash_output)
    evidence["bash"] = {"start": bash, "polls": bash_polls}

    release_file = f"{root}/release-second"
    session = successful(run_bash(
        base_url,
        f"printf first; while [ ! -f {release_file} ]; do sleep 0.1; done; "
        "printf second",
        f"docker-contract-incremental-{time.time_ns()}",
        yield_ms=50,
        timeout_ms=120000,
    ))
    chunks = [session.get("output", "")]
    polls = []
    terminal = session
    cursor = session.get("next-cursor", 0)
    deadline = time.monotonic() + 45
    while "first" not in "".join(chunks) and time.monotonic() < deadline:
        require(terminal.get("execution-status") == "running", terminal)
        terminal = successful(request(
            base_url,
            "bash-session",
            {
                "session-id": session["session-id"],
                "cursor": cursor,
                "wait-ms": 200,
                "terminate": False,
            },
        ))
        polls.append(terminal)
        chunks.append(terminal.get("output", ""))
        cursor = terminal.get("next-cursor", cursor)
    require("".join(chunks) == "first", chunks)
    require(terminal.get("execution-status") == "running", terminal)
    successful(request(
        base_url, "write", {"path": release_file, "content": "release"}
    ))
    deadline = time.monotonic() + 45
    while terminal.get("execution-status") == "running" and time.monotonic() < deadline:
        terminal = successful(request(
            base_url,
            "bash-session",
            {
                "session-id": session["session-id"],
                "cursor": cursor,
                "wait-ms": 200,
                "terminate": False,
            },
        ))
        polls.append(terminal)
        chunks.append(terminal.get("output", ""))
        cursor = terminal.get("next-cursor", cursor)
    require("".join(chunks) == "firstsecond", chunks)
    require(terminal.get("execution-status") == "exited", terminal)
    require(any("first" in chunk for chunk in chunks[:-1]), chunks)
    require(any("second" in chunk for chunk in chunks[1:]), chunks)
    evidence["bash-session-incremental"] = {"start": session, "polls": polls}

    terminating = successful(run_bash(
        base_url,
        "printf terminating; sleep 30",
        f"docker-contract-terminate-{time.time_ns()}",
        yield_ms=50,
        timeout_ms=60000,
    ))
    terminated = successful(request(
        base_url,
        "bash-session",
        {
            "session-id": terminating["session-id"],
            "cursor": terminating.get("next-cursor", 0),
            "wait-ms": 5000,
            "terminate": True,
        },
    ))
    require(terminated.get("execution-status") == "terminated", terminated)
    require(terminated.get("exit-code") == 143, terminated)
    evidence["bash-session-termination"] = {
        "start": terminating,
        "terminal": terminated,
    }

    isolated = request(
        base_url, "read", {"path": route_file}, member=OTHER_MEMBER
    )
    require(isolated.get("status") == 404, isolated)
    evidence["member-isolation"] = isolated

    network_url = args.network_url.replace("'", "'%27'")
    denied = successful(run_bash(
        base_url,
        "! python3 -c 'import urllib.request; "
        f"urllib.request.urlopen(\"{network_url}\", timeout=2)' >/dev/null 2>&1",
        "docker-contract-network-default-denied",
        yield_ms=5000,
    ))
    require(denied.get("exit-code") == 0, denied)
    evidence["network-default-denied"] = denied

    immutable_session = successful(run_bash(
        base_url,
        "sleep 2; ! python3 -c 'import urllib.request; "
        f"urllib.request.urlopen(\"{network_url}\", timeout=2)' >/dev/null 2>&1; "
        "printf policy-held",
        f"docker-contract-network-immutable-{time.time_ns()}",
        member=NETWORK_LOCK_MEMBER,
        allow_network=False,
        yield_ms=50,
        timeout_ms=15000,
    ))
    immutable_change = run_bash(
        base_url,
        "printf must-not-run",
        f"docker-contract-network-change-{time.time_ns()}",
        member=NETWORK_LOCK_MEMBER,
        allow_network=True,
        yield_ms=5000,
    )
    require(immutable_change.get("status") == 409, immutable_change)
    immutable_output, immutable_terminal, immutable_polls = collect_session(
        base_url,
        immutable_session,
        member=NETWORK_LOCK_MEMBER,
    )
    require(immutable_terminal.get("execution-status") == "exited",
            immutable_terminal)
    require(immutable_terminal.get("exit-code") == 0, immutable_terminal)
    require(immutable_output == "policy-held", immutable_output)
    evidence["network-policy-immutable"] = {
        "start": immutable_session,
        "change": immutable_change,
        "polls": immutable_polls,
    }

    restored = successful(run_bash(
        base_url,
        "python3 -c 'import urllib.request; "
        f"print(urllib.request.urlopen(\"{network_url}\", timeout=10).read().decode())'",
        "docker-contract-network-enabled",
        member=NETWORK_MEMBER,
        allow_network=True,
        yield_ms=15000,
        timeout_ms=15000,
    ))
    require(restored.get("exit-code") == 0, restored)
    require("LAPEE_DOCKER_NETWORK_OK" in restored.get("output", ""), restored)
    evidence["network-enabled"] = restored
    immutable_disable = run_bash(
        base_url,
        "printf must-not-run",
        "docker-contract-network-disable-rejected",
        member=NETWORK_MEMBER,
        allow_network=False,
        yield_ms=5000,
    )
    require(immutable_disable.get("status") == 409, immutable_disable)
    still_enabled = successful(run_bash(
        base_url,
        "python3 -c 'import urllib.request; "
        f"print(urllib.request.urlopen(\"{network_url}\", timeout=10).read().decode())'",
        "docker-contract-network-still-enabled",
        member=NETWORK_MEMBER,
        allow_network=True,
        yield_ms=15000,
        timeout_ms=15000,
    ))
    require("LAPEE_DOCKER_NETWORK_OK" in still_enabled.get("output", ""),
            still_enabled)
    evidence["network-enable-immutable"] = {
        "change": immutable_disable,
        "proof": still_enabled,
    }

    limits = successful(run_bash(
        base_url,
        "printf 'memory='; cat /sys/fs/cgroup/memory.max; "
        "printf 'cpu='; cat /sys/fs/cgroup/cpu.max; "
        "printf 'pids='; cat /sys/fs/cgroup/pids.max; "
        "grep -E '^(CapEff|NoNewPrivs|Seccomp):' /proc/self/status; "
        "df -B1 /root | tail -1 | awk '{print \"storage=\" $2}'",
        "docker-contract-resource-config",
        yield_ms=5000,
    ))
    limit_output = limits.get("output", "")
    require("memory=536870912" in limit_output, limit_output)
    require("cpu=100000 100000" in limit_output, limit_output)
    require("pids=256" in limit_output, limit_output)
    require(re.search(r"CapEff:\s+0+\n", limit_output), limit_output)
    require(re.search(r"NoNewPrivs:\s+1\n", limit_output), limit_output)
    require(re.search(r"Seccomp:\s+2\n", limit_output), limit_output)
    storage_match = re.search(r"storage=(\d+)", limit_output)
    require(storage_match and int(storage_match.group(1)) <= 128 * 1024 * 1024,
            limit_output)
    evidence["resource-config"] = limits

    pid_probe = successful(run_bash(
        base_url,
        "resource-probe pids 400",
        "docker-contract-pids-enforced",
        yield_ms=15000,
        timeout_ms=15000,
    ))
    pid_match = re.search(r"started-pids=(\d+)", pid_probe.get("output", ""))
    require(pid_match and int(pid_match.group(1)) < 400, pid_probe)
    evidence["pids-enforced"] = pid_probe

    cpu_probe = successful(run_bash(
        base_url,
        "for n in 1 2 3 4; do resource-probe cpu 4 & done; wait",
        "docker-contract-cpu-enforced",
        yield_ms=15000,
        timeout_ms=15000,
    ))
    cpu_seconds = [
        float(value)
        for value in re.findall(r"cpu-seconds=([0-9.]+)", cpu_probe.get("output", ""))
    ]
    require(len(cpu_seconds) == 4 and sum(cpu_seconds) < 8.0, cpu_probe)
    evidence["cpu-enforced"] = cpu_probe

    storage_probe = successful(run_bash(
        base_url,
        "if dd if=/dev/zero of=/root/storage-bound.bin bs=1M count=192 2>/dev/null; "
        "then rc=0; else rc=$?; fi; rm -f /root/storage-bound.bin; "
        "printf 'storage-write-exit=%s' \"$rc\"",
        "docker-contract-storage-enforced",
        yield_ms=30000,
        timeout_ms=30000,
    ))
    storage_exit = re.search(
        r"storage-write-exit=(\d+)", storage_probe.get("output", "")
    )
    require(storage_exit and int(storage_exit.group(1)) != 0, storage_probe)
    evidence["storage-enforced"] = storage_probe

    memory_probe = run_bash(
        base_url,
        "resource-probe memory 640",
        "docker-contract-memory-enforced",
        yield_ms=15000,
        timeout_ms=15000,
    )
    if memory_probe.get("status") == 200:
        memory_probe = successful(memory_probe)
        require(memory_probe.get("exit-code") != 0, memory_probe)
    else:
        require(memory_probe.get("status", 0) >= 400, memory_probe)
    evidence["memory-enforced"] = memory_probe

    successful(request(base_url, "write", {
        "path": f"{root}/persistent.txt", "content": "survives-restart"
    }))
    before_restart = successful(run_bash(
        base_url,
        "awk '{print $22}' /proc/1/stat",
        "docker-contract-before-restart",
        yield_ms=5000,
    ))
    stop_response = run_bash(
        base_url,
        "kill -TERM 1",
        "docker-contract-stop-container",
        yield_ms=5000,
        timeout_ms=5000,
    )
    time.sleep(2)
    persisted = successful(request(
        base_url, "read", {"path": f"{root}/persistent.txt"}, timeout=120
    ))
    require(persisted.get("content") == "survives-restart", persisted)
    after_restart = successful(run_bash(
        base_url,
        "awk '{print $22}' /proc/1/stat",
        "docker-contract-after-restart",
        yield_ms=5000,
    ))
    require(
        before_restart.get("output", "").strip()
        != after_restart.get("output", "").strip(),
        {"before": before_restart, "after": after_restart},
    )
    evidence["stop-restart-persistence"] = {
        "before": before_restart,
        "stop-response": stop_response,
        "read-after-restart": persisted,
        "after": after_restart,
    }

    evidence["contract-parity"] = cross_backend_contract(base_url)

    evidence["consumer"] = "public-hyperbeam-route"
    evidence["backend"] = "docker@1.0"
    evidence["passed"] = True
    args.evidence.parent.mkdir(parents=True, exist_ok=True)
    args.evidence.write_text(json.dumps(evidence, indent=2, sort_keys=True) + "\n")
    print("DOCKER_DEVICE_ROUTE_SMOKE_OK")


if __name__ == "__main__":
    main()
