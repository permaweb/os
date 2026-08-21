#!/usr/bin/env python3
"""Exercise the generic Andock contract through public AO-Core HTTP routes."""

import argparse
import json
import pathlib
import time
import urllib.error
import urllib.request


TOOLS = ["Read", "Write", "Append", "Edit", "Glob", "Grep", "Bash"]
MEMBER = "neutral-contract-probe"


def request(base_url, action, body=None, tools=TOOLS, method="POST"):
    url = f"{base_url}/~andock@1.0/{action}"
    data = None
    headers = {"accept": "application/json", "accept-bundle": "true"}
    if body is not None:
        message = {
            "body": {"member-id": MEMBER, **body},
            "member-context": {
                "id": MEMBER,
                "tools": tools,
                "metadata": {"allow-network": False},
            },
        }
        data = json.dumps(message, separators=(",", ":")).encode()
        headers["content-type"] = "application/json"
    try:
        with urllib.request.urlopen(
            urllib.request.Request(url, data=data, headers=headers, method=method),
            timeout=60,
        ) as response:
            return json.load(response)
    except urllib.error.HTTPError as failure:
        return json.load(failure)


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def wait_for_template(base_url, timeout):
    deadline = time.monotonic() + timeout
    while True:
        response = request(base_url, "bash", {
            "command": "true",
            "cwd": "/root",
            "yield-ms": 5000,
            "execution-id": "andock-template-readiness",
        })
        if response.get("status") == 200:
            require(response.get("execution-status") == "exited", response)
            require(response.get("exit-code") == 0, response)
            return response
        if (
            response.get("status") != 503
            or not response.get("error", "").startswith("andock-default-image-")
            or time.monotonic() >= deadline
        ):
            raise AssertionError(response)
        time.sleep(2)


def successful(response):
    require(response.get("status") == 200, response)
    require(response.get("ok") in (True, "true"), response)
    require(response.get("device") == "andock@1.0", response)
    return response


def collect_session(base_url, started):
    output = started.get("output", "")
    cursor = started.get("next-cursor", 0)
    polls = []
    current = started
    for _ in range(40):
        if current.get("execution-status") != "running":
            break
        current = successful(request(base_url, "bash-session", {
            "session-id": started["session-id"],
            "cursor": cursor,
            "wait-ms": 200,
            "terminate": False,
        }))
        polls.append(current)
        output += current.get("output", "")
        cursor = current.get("next-cursor", cursor)
    require(current.get("execution-status") != "running", polls)
    return output, current, polls


def run_bash_to_completion(base_url, body):
    started = successful(request(base_url, "bash", body))
    if started.get("execution-status") == "running":
        output, terminal, polls = collect_session(base_url, started)
    else:
        output = started.get("output", "")
        terminal = started
        polls = []
    require(terminal.get("execution-status") == "exited", terminal)
    return output, terminal, polls


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-url", required=True)
    parser.add_argument("--evidence", type=pathlib.Path, required=True)
    parser.add_argument("--materialization-timeout", type=int, default=1800)
    args = parser.parse_args()
    base_url = args.base_url.rstrip("/")
    evidence = {}

    index = request(base_url, "index", method="GET")
    require(index.get("status") == 200, index)
    require(index.get("device") == "andock@1.0", index)
    require(
        index.get("keys")
        == ["read", "write", "append", "edit", "glob", "grep", "bash", "bash-session"],
        index,
    )
    evidence["index"] = index
    evidence["template-readiness"] = wait_for_template(
        base_url,
        args.materialization_timeout,
    )

    root = "/root/neutral-contract-probe"
    route_file = f"{root}/route.txt"
    run_bash_to_completion(base_url, {
        "command": f"rm -rf -- {root}; mkdir -p -- {root}",
        "cwd": "/root",
        "yield-ms": 5000,
        "execution-id": "neutral-contract-clean-start",
    })
    evidence["write"] = successful(request(base_url, "write", {
        "path": route_file,
        "content": "alpha",
    }))
    evidence["append"] = successful(request(base_url, "append", {
        "path": route_file,
        "content": "beta",
    }))
    evidence["edit"] = successful(request(base_url, "edit", {
        "path": route_file,
        "old-string": "beta",
        "new-string": "gamma",
    }))
    evidence["read"] = successful(request(base_url, "read", {"path": route_file}))
    require(evidence["read"].get("content") == "alphagamma", evidence["read"])
    evidence["glob"] = successful(request(base_url, "glob", {
        "pattern": "missing-*.txt",
        "cwd": root,
    }))
    require(evidence["glob"].get("matches") == [], evidence["glob"])
    evidence["grep"] = successful(request(base_url, "grep", {
        "pattern": "definitely-not-present",
        "cwd": root,
    }))
    require(evidence["grep"].get("matches") == [], evidence["grep"])

    bash_start = successful(request(base_url, "bash", {
        "command": "printf shell-ok",
        "cwd": root,
        "yield-ms": 5000,
        "execution-id": "neutral-contract-bash",
    }))
    bash_output, bash_terminal, bash_polls = collect_session(base_url, bash_start)
    require(bash_terminal.get("execution-status") == "exited", bash_terminal)
    require(bash_output == "shell-ok", bash_output)
    evidence["bash"] = {"start": bash_start, "polls": bash_polls}

    session = successful(request(base_url, "bash", {
        "command": "printf ready; sleep 5; printf done",
        "cwd": root,
        "yield-ms": 50,
        "execution-id": f"neutral-contract-session-{time.time_ns()}",
    }))
    conflict_started = time.monotonic()
    bash_conflict = request(base_url, "bash", {
        "command": "printf must-not-run",
        "cwd": root,
        "yield-ms": 0,
        "execution-id": f"neutral-contract-conflict-{time.time_ns()}",
    })
    bash_conflict_elapsed = time.monotonic() - conflict_started
    require(bash_conflict.get("status") == 409, bash_conflict)
    require(bash_conflict.get("error") == "member-session-active", bash_conflict)
    require(bash_conflict.get("session-id") == session["session-id"], bash_conflict)
    require(bash_conflict.get("execution-status") == "running", bash_conflict)
    require(bash_conflict.get("session-control-action") == "bash-session", bash_conflict)
    require(
        bash_conflict.get("session-control-operations")
        == ["poll", "wait", "terminate"],
        bash_conflict,
    )
    require(bash_conflict_elapsed < 3, bash_conflict_elapsed)
    read_conflict_started = time.monotonic()
    read_conflict = request(base_url, "read", {"path": route_file})
    read_conflict_elapsed = time.monotonic() - read_conflict_started
    require(read_conflict.get("status") == 409, read_conflict)
    require(read_conflict.get("error") == "member-session-active", read_conflict)
    require(read_conflict.get("session-id") == session["session-id"], read_conflict)
    require(read_conflict_elapsed < 3, read_conflict_elapsed)
    session_alive = successful(request(base_url, "bash-session", {
        "session-id": session["session-id"],
        "cursor": 0,
        "wait-ms": 0,
        "terminate": False,
    }))
    require(session_alive.get("execution-status") == "running", session_alive)
    output, terminal, polls = collect_session(base_url, session)
    require(output == "readydone", {"output": output, "polls": polls})
    require(terminal.get("execution-status") == "exited", terminal)
    evidence["bash-session"] = {
        "start": session,
        "bash-conflict": bash_conflict,
        "bash-conflict-elapsed-seconds": bash_conflict_elapsed,
        "read-conflict": read_conflict,
        "read-conflict-elapsed-seconds": read_conflict_elapsed,
        "alive-after-conflicts": session_alive,
        "polls": polls,
    }

    terminate_session = successful(request(base_url, "bash", {
        "command": "printf terminating; sleep 30",
        "cwd": root,
        "yield-ms": 50,
        "execution-id": f"neutral-contract-terminate-{time.time_ns()}",
    }))
    terminated = successful(request(base_url, "bash-session", {
        "session-id": terminate_session["session-id"],
        "cursor": terminate_session.get("next-cursor", 0),
        "wait-ms": 5000,
        "terminate": True,
    }))
    require(terminated.get("execution-status") == "terminated", terminated)
    require(terminated.get("exit-code") == 143, terminated)
    evidence["bash-session-termination"] = {
        "start": terminate_session,
        "terminal": terminated,
    }

    evidence["write-file"] = successful(request(base_url, "write-file", {
        "path": f"{root}/integration.bin",
        "content": "binary-data",
    }))
    evidence["read-file"] = successful(request(base_url, "read-file", {
        "path": f"{root}/integration.bin",
    }))
    require(evidence["read-file"].get("content") == "binary-data", evidence["read-file"])
    evidence["list-files"] = successful(request(base_url, "list-files", {"path": root}))
    require(
        {entry.get("name") for entry in evidence["list-files"].get("entries", [])}
        == {"integration.bin", "route.txt"},
        evidence["list-files"],
    )

    evidence["unknown"] = request(base_url, "unknown", method="GET")
    require(evidence["unknown"].get("status") == 404, evidence["unknown"])
    evidence["traversal"] = request(base_url, "read", {"path": "../secret"})
    require(evidence["traversal"].get("status") == 400, evidence["traversal"])
    evidence["unauthorized"] = request(
        base_url,
        "bash",
        {"command": "true", "yield-ms": 0},
        tools=["Read"],
    )
    require(evidence["unauthorized"].get("status") == 403, evidence["unauthorized"])
    network_output, network_terminal, network_polls = run_bash_to_completion(base_url, {
        "command": "bash -c 'exec 3<>/dev/tcp/1.1.1.1/80' >/dev/null 2>&1",
        "cwd": root,
        "yield-ms": 5000,
        "timeout-ms": 5000,
        "execution-id": "neutral-contract-network-denied",
    })
    evidence["network-denied"] = {
        "output": network_output,
        "terminal": network_terminal,
        "polls": network_polls,
    }
    require(network_terminal.get("exit-code") != 0, evidence["network-denied"])

    run_bash_to_completion(base_url, {
        "command": f"rm -rf -- {root}",
        "cwd": "/root",
        "yield-ms": 5000,
        "execution-id": f"neutral-contract-clean-end-{time.time_ns()}",
    })
    evidence["consumer"] = "neutral-contract-probe"
    evidence["passed"] = True
    args.evidence.parent.mkdir(parents=True, exist_ok=True)
    args.evidence.write_text(json.dumps(evidence, indent=2, sort_keys=True) + "\n")
    print("ANDOCK_DEVICE_ROUTE_SMOKE_OK")


if __name__ == "__main__":
    main()
