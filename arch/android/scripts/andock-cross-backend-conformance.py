#!/usr/bin/env python3
"""Compare representative docker@1.0 and andock@1.0 contract results."""

import argparse
import json
import pathlib
import time
import urllib.error
import urllib.request


TOOLS = ["Read", "Write", "Append", "Edit", "Glob", "Grep", "Bash"]
MEMBER = "neutral-contract-probe"


def request(base_url, action, body, tools=TOOLS):
    message = {
        "body": {"member-id": MEMBER, **body},
        "member-context": {
            "id": MEMBER,
            "tools": tools,
            "metadata": {"allow-network": False},
        },
    }
    data = json.dumps(message, separators=(",", ":")).encode()
    headers = {
        "accept": "application/json",
        "accept-bundle": "true",
        "content-type": "application/json",
    }
    try:
        with urllib.request.urlopen(
            urllib.request.Request(
                f"{base_url}/~andock@1.0/{action}",
                data=data,
                headers=headers,
                method="POST",
            ),
            timeout=90,
        ) as response:
            return json.load(response)
    except urllib.error.HTTPError as failure:
        return json.load(failure)


def require(condition, details):
    if not condition:
        raise AssertionError(json.dumps(details, indent=2, sort_keys=True))


def collect_session(base_url, started):
    output = started.get("output", "")
    current = started
    polls = 0
    while current.get("execution-status") == "running" and polls < 30:
        current = request(
            base_url,
            "bash-session",
            {
                "session-id": started["session-id"],
                "cursor": current.get("next-cursor", 0),
                "wait-ms": 200,
            },
        )
        output += current.get("output", "")
        polls += 1
    require(current.get("execution-status") != "running", current)
    return {"output": output, "terminal": current, "polls": polls}


def run_andock(base_url):
    request(
        base_url,
        "bash",
        {
            "command": "rm -rf -- /root/parity",
            "cwd": "/root",
            "yield-ms": 5000,
            "execution-id": f"parity-clean-{time.time_ns()}",
        },
    )
    evidence = {}
    evidence["write"] = request(
        base_url, "write", {"path": "parity/a.txt", "content": "alpha"}
    )
    evidence["append"] = request(
        base_url, "append", {"path": "parity/a.txt", "content": "beta"}
    )
    evidence["edit"] = request(
        base_url,
        "edit",
        {
            "path": "parity/a.txt",
            "old-string": "beta",
            "new-string": "gamma",
        },
    )
    evidence["read"] = request(base_url, "read", {"path": "parity/a.txt"})
    evidence["glob"] = request(
        base_url,
        "glob",
        {"pattern": "missing-*.txt", "cwd": "/root/parity"},
    )
    evidence["grep"] = request(
        base_url,
        "grep",
        {"pattern": "definitely-not-present", "cwd": "/root/parity"},
    )
    evidence["bash"] = request(
        base_url,
        "bash",
        {
            "command": "printf contract-ok",
            "cwd": "/root",
            "yield-ms": 5000,
            "execution-id": f"parity-bash-{time.time_ns()}",
        },
    )
    evidence["missing"] = request(
        base_url, "read", {"path": "parity/missing.txt"}
    )
    evidence["unauthorized"] = request(
        base_url, "bash", {"command": "printf denied"}, tools=["Read"]
    )
    evidence["list-files"] = request(
        base_url, "list-files", {"path": "/root/parity"}
    )
    started = request(
        base_url,
        "bash",
        {
            "command": "printf one; sleep 1; printf two",
            "yield-ms": 50,
            "execution-id": f"parity-session-{time.time_ns()}",
        },
    )
    evidence["session"] = collect_session(base_url, started)
    terminate_started = request(
        base_url,
        "bash",
        {
            "command": "sleep 30",
            "yield-ms": 50,
            "execution-id": f"parity-terminate-{time.time_ns()}",
        },
    )
    evidence["terminated-session"] = request(
        base_url,
        "bash-session",
        {
            "session-id": terminate_started["session-id"],
            "cursor": terminate_started.get("next-cursor", 0),
            "wait-ms": 5000,
            "terminate": True,
        },
    )
    evidence["timeout"] = request(
        base_url,
        "bash",
        {
            "command": "sleep 2",
            "yield-ms": 5000,
            "timeout-ms": 100,
            "execution-id": f"parity-timeout-{time.time_ns()}",
        },
    )
    return evidence


def bool_value(value):
    if value == "true":
        return True
    if value == "false":
        return False
    return value


def fields(response, names):
    result = {"status": response.get("status", 200)}
    for name in names:
        if name in response:
            result[name] = bool_value(response[name])
    return result


def project(evidence):
    common = ["action", "ok"]
    projected = {
        "write": fields(
            evidence["write"], common + ["bytes", "path", "output", "deltas"]
        ),
        "append": fields(
            evidence["append"], common + ["bytes", "path", "output", "deltas"]
        ),
        "edit": fields(
            evidence["edit"],
            common + ["path", "output", "replacements", "deltas"],
        ),
        "read": fields(
            evidence["read"],
            common + ["path", "content", "output", "size", "truncated", "deltas"],
        ),
        "glob": fields(
            evidence["glob"],
            common
            + ["cwd", "pattern", "matches", "output", "exit-code", "truncated"],
        ),
        "grep": fields(
            evidence["grep"],
            common
            + ["cwd", "pattern", "matches", "output", "exit-code", "truncated"],
        ),
        "bash": fields(
            evidence["bash"],
            common
            + [
                "command",
                "cwd",
                "output",
                "exit-code",
                "execution-status",
                "disable-network",
                "truncated",
                "output-limit-reached",
            ],
        ),
        "missing": fields(
            evidence["missing"], common + ["path", "error"]
        ),
        "unauthorized": fields(
            evidence["unauthorized"], common + ["error"]
        ),
        "terminated-session": fields(
            evidence["terminated-session"],
            common
            + [
                "execution-status",
                "exit-code",
                "truncated",
                "output-limit-reached",
            ],
        ),
        "timeout": fields(
            evidence["timeout"],
            common
            + [
                "command",
                "cwd",
                "execution-status",
                "exit-code",
                "timeout-ms",
                "truncated",
                "output-limit-reached",
            ],
        ),
    }
    entries = []
    for entry in evidence["list-files"].get("entries", []):
        entries.append(
            {
                key: entry[key]
                for key in ["name", "path", "size", "type"]
                if key in entry
            }
        )
    projected["list-files"] = {
        "status": evidence["list-files"].get("status", 200),
        "path": evidence["list-files"].get("path"),
        "entries": entries,
    }
    terminal = evidence["session"]["terminal"]
    projected["session"] = {
        "output": evidence["session"]["output"],
        **fields(
            terminal,
            [
                "action",
                "ok",
                "execution-status",
                "exit-code",
                "truncated",
                "output-limit-reached",
            ],
        ),
    }
    return projected


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-url", required=True)
    parser.add_argument("--docker-evidence", type=pathlib.Path, required=True)
    parser.add_argument("--evidence", type=pathlib.Path, required=True)
    args = parser.parse_args()
    docker = json.loads(args.docker_evidence.read_text())
    andock = run_andock(args.base_url.rstrip("/"))
    docker_projection = project(docker)
    andock_projection = project(andock)
    require(
        docker_projection == andock_projection,
        {"docker": docker_projection, "andock": andock_projection},
    )
    report = {
        "passed": True,
        "docker-backend": docker["backend"],
        "andock-backend": "andock@1.0",
        "docker": docker,
        "andock": andock,
        "normalized-contract": docker_projection,
    }
    args.evidence.parent.mkdir(parents=True, exist_ok=True)
    args.evidence.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print("ANDOCK_CROSS_BACKEND_CONFORMANCE_OK")


if __name__ == "__main__":
    main()
