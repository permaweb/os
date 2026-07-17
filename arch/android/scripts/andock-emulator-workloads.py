#!/usr/bin/env python3

import argparse
import base64
import json
from pathlib import Path
import time

from andock_emulator_client import (
    PACKAGE,
    Client,
    decode_output,
    exec_command,
    require,
    success,
)


class Workloads:
    def __init__(self, client, member):
        self.client = client
        self.member = member
        self.evidence = []

    def run(self, name, command, timeout=30_000, allow_network=False, expect=0):
        started = time.monotonic()
        response = exec_command(
            self.client,
            self.member,
            command,
            timeout=timeout,
            allow_network=allow_network,
        )
        elapsed = time.monotonic() - started
        output = decode_output(response).decode(errors="replace")
        exit_code = response["body"]["exit-code"]
        self.evidence.append({
            "name": name,
            "seconds": round(elapsed, 3),
            "exit-code": exit_code,
            "timed-out": response["body"]["timed-out"],
            "output-tail": output[-4000:],
        })
        require(exit_code == expect, f"{name}: exit {exit_code}\n{output}")
        require(not response["body"]["timed-out"], f"{name}: timed out")
        print(f"{name}: {elapsed:.3f}s")
        return output

    def write(self, path, content):
        encoded = base64.urlsafe_b64encode(content.encode()).decode().rstrip("=")
        success(self.client.request("write", self.member, path=path, content=encoded))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--adb", default="adb")
    parser.add_argument("--serial", required=True)
    parser.add_argument("--member", default="andock-workloads")
    parser.add_argument(
        "--evidence",
        default="arch/android/build/andock-emulator-workloads.json",
    )
    parser.add_argument("--keep-member", action="store_true")
    arguments = parser.parse_args()

    client = Client(arguments.adb, arguments.serial)
    client.wait_until_ready()
    workloads = Workloads(client, arguments.member)
    run_started = time.monotonic()

    try:
        client.request("destroy", arguments.member)
        base = workloads.run(
            "base-environment",
            "set -eu; . /etc/os-release; "
            "printf 'os=%s %s\\n' \"$NAME\" \"$VERSION_ID\"; "
            "printf 'arch=%s\\n' \"$(uname -m)\"; "
            "printf 'python=%s\\n' \"$(python3 --version)\"; "
            "printf 'node=%s\\n' \"$(node --version)\"; "
            "df -B1 /; test -w /usr -a -w /etc -a -w /var -a -w /root",
        )
        require("Ubuntu 24.04" in base, base)
        require("arch=aarch64" in base, base)

        workloads.run(
            "apt-install",
            "set -eu; apt-get update; "
            "apt-get install -y --no-install-recommends "
            "dnsutils netcat-openbsd strace tree; "
            "printf '#!/bin/sh\\nprintf andock-apt-ok\\n' "
            ">/usr/local/bin/andock-apt-check; "
            "chmod 0755 /usr/local/bin/andock-apt-check; "
            "andock-apt-check; dpkg-query -W dnsutils tree",
            timeout=900_000,
            allow_network=True,
        )

        workloads.run(
            "pip-system-install",
            "set -eu; pip install --no-cache-dir --disable-pip-version-check requests; "
            "python3 -c 'import requests; print(requests.__version__, requests.__file__)'; "
            "case \"$(python3 -c 'import requests; print(requests.__file__)')\" "
            "in /usr/local/lib/python3.12/dist-packages/*) ;; *) exit 1;; esac",
            timeout=600_000,
            allow_network=True,
        )
        workloads.run(
            "pip-venv-install",
            "set -eu; python3 -m venv /root/venv; "
            "/root/venv/bin/pip install --no-cache-dir --disable-pip-version-check idna; "
            "/root/venv/bin/python -c 'import idna; print(idna.__version__)'",
            timeout=300_000,
            allow_network=True,
        )

        workloads.write(
            "/root/node-addon/binding.gyp",
            '{"targets":[{"target_name":"answer","sources":["answer.cc"]}]}\n',
        )
        workloads.write(
            "/root/node-addon/answer.cc",
            "#include <node.h>\n"
            "namespace demo {\n"
            "using v8::FunctionCallbackInfo; using v8::Isolate; using v8::Number;\n"
            "using v8::Object; using v8::Value;\n"
            "void Answer(const FunctionCallbackInfo<Value>& args) {\n"
            "  args.GetReturnValue().Set(Number::New(args.GetIsolate(), 42));\n"
            "}\n"
            "void Init(Object exports) { NODE_SET_METHOD(exports, \"answer\", Answer); }\n"
            "NODE_MODULE(NODE_GYP_MODULE_NAME, Init)\n"
            "}\n",
        )
        workloads.run(
            "npm-and-native-addon",
            "set -eu; cd /root/node-addon; npm init -y >/dev/null; "
            "npm install --no-audit --no-fund typescript node-gyp; "
            "npx tsc --version; npx node-gyp rebuild; "
            "node -e \"const a=require('./build/Release/answer'); "
            "if(a.answer()!==42) process.exit(1); console.log(a.answer())\"",
            timeout=900_000,
            allow_network=True,
        )

        workloads.run(
            "filesystem-scale",
            "set -eu; rm -rf /root/many; mkdir /root/many; "
            "python3 - <<'PY'\n"
            "from pathlib import Path\n"
            "root = Path('/root/many')\n"
            "for index in range(10000):\n"
            "    (root / f'{index:05d}').write_text(str(index))\n"
            "PY\n"
            "test \"$(find /root/many -type f | wc -l)\" -eq 10000; "
            "du -sh /root/many",
            timeout=600_000,
        )
        workloads.run(
            "linux-ipc-and-mmap",
            "set -eu; python3 - <<'PY'\n"
            "from multiprocessing import shared_memory\n"
            "import mmap, os, socket\n"
            "shared = shared_memory.SharedMemory(create=True, size=32)\n"
            "shared.buf[:4] = b'good'\n"
            "assert bytes(shared.buf[:4]) == b'good'\n"
            "shared.close(); shared.unlink()\n"
            "with open('/root/mmap-data', 'w+b') as output:\n"
            "    output.truncate(4096)\n"
            "    with mmap.mmap(output.fileno(), 4096) as mapped:\n"
            "        mapped[:4] = b'mmap'; mapped.flush()\n"
            "server = socket.socket(socket.AF_UNIX)\n"
            "server.bind('/root/andock.sock'); server.close()\n"
            "os.unlink('/root/andock.sock')\n"
            "PY\n"
            "test \"$(head -c 4 /root/mmap-data)\" = mmap",
        )
        workloads.run(
            "linux-file-syscalls",
            "set -eu; python3 - <<'PY'\n"
            "import errno, fcntl, multiprocessing, os\n"
            "source_data = bytes(range(256)) * 4096\n"
            "with open('/root/syscall-source', 'wb') as output:\n"
            "    output.write(source_data)\n"
            "source = os.open('/root/syscall-source', os.O_RDONLY)\n"
            "independent = os.open('/root/syscall-source', os.O_RDONLY)\n"
            "destination = os.open('/root/sendfile-copy', os.O_CREAT | os.O_RDWR, 0o644)\n"
            "os.lseek(source, 123, os.SEEK_SET)\n"
            "assert os.sendfile(destination, source, None, 65536) == 65536\n"
            "assert os.lseek(source, 0, os.SEEK_CUR) == 65659\n"
            "assert os.lseek(independent, 0, os.SEEK_CUR) == 0\n"
            "assert os.pread(destination, 65536, 0) == source_data[123:65659]\n"
            "os.close(destination); os.close(independent); os.close(source)\n"
            "source = os.open('/root/syscall-source', os.O_RDONLY)\n"
            "destination = os.open('/root/copy-range', os.O_CREAT | os.O_RDWR, 0o644)\n"
            "assert os.copy_file_range(source, destination, 131072) == 131072\n"
            "assert os.pread(destination, 131072, 0) == source_data[:131072]\n"
            "os.close(destination); os.close(source)\n"
            "source = os.open('/root/syscall-source', os.O_RDONLY)\n"
            "destination = os.open('/root/splice-copy', os.O_CREAT | os.O_RDWR, 0o644)\n"
            "reader, writer = os.pipe()\n"
            "assert os.splice(source, writer, 65536) == 65536\n"
            "assert os.splice(reader, destination, 65536) == 65536\n"
            "assert os.pread(destination, 65536, 0) == source_data[:65536]\n"
            "for descriptor in (reader, writer, destination, source): os.close(descriptor)\n"
            "allocated = os.open('/root/fallocate', os.O_CREAT | os.O_RDWR, 0o644)\n"
            "os.posix_fallocate(allocated, 0, 1024 * 1024)\n"
            "assert os.fstat(allocated).st_size == 1024 * 1024\n"
            "assert os.pread(allocated, 16, 512 * 1024) == bytes(16)\n"
            "os.close(allocated)\n"
            "readonly = os.open('/root/fallocate', os.O_RDONLY)\n"
            "try:\n"
            "    os.posix_fallocate(readonly, 0, 2 * 1024 * 1024)\n"
            "except OSError as failure:\n"
            "    assert failure.errno == errno.EBADF, failure\n"
            "else:\n"
            "    raise AssertionError('read-only fallocate succeeded')\n"
            "os.close(readonly)\n"
            "first = os.open('/root/flock', os.O_CREAT | os.O_RDWR, 0o644)\n"
            "second = os.open('/root/flock', os.O_RDWR)\n"
            "fcntl.flock(first, fcntl.LOCK_EX | fcntl.LOCK_NB)\n"
            "try:\n"
            "    fcntl.flock(second, fcntl.LOCK_EX | fcntl.LOCK_NB)\n"
            "except BlockingIOError:\n"
            "    pass\n"
            "else:\n"
            "    raise AssertionError('independent flock did not conflict')\n"
            "fcntl.flock(first, fcntl.LOCK_UN); os.close(second); os.close(first)\n"
            "def append(label):\n"
            "    descriptor = os.open('/root/append', os.O_CREAT | os.O_WRONLY | os.O_APPEND, 0o644)\n"
            "    for index in range(100): os.write(descriptor, f'{label}:{index}\\n'.encode())\n"
            "    os.close(descriptor)\n"
            "workers = [multiprocessing.Process(target=append, args=(label,)) for label in ('a', 'b')]\n"
            "for worker in workers: worker.start()\n"
            "for worker in workers: worker.join(); assert worker.exitcode == 0\n"
            "lines = open('/root/append').read().splitlines()\n"
            "assert len(lines) == len(set(lines)) == 200\n"
            "PY",
            timeout=300_000,
        )

        workloads.run(
            "python-ml-install",
            "set -eu; pip install --no-cache-dir --disable-pip-version-check "
            "transformers torch; "
            "python3 - <<'PY'\n"
            "import torch, transformers\n"
            "assert torch.tensor([6, 7]).prod().item() == 42\n"
            "print('torch', torch.__version__)\n"
            "print('transformers', transformers.__version__)\n"
            "PY",
            timeout=1_800_000,
            allow_network=True,
        )
        workloads.run(
            "huggingface-tiny-model",
            "set -eu; python3 - <<'PY'\n"
            "from transformers import AutoModel, AutoTokenizer\n"
            "name = 'hf-internal-testing/tiny-random-bert'\n"
            "tokenizer = AutoTokenizer.from_pretrained(name)\n"
            "model = AutoModel.from_pretrained(name)\n"
            "output = model(**tokenizer('Andock on Android', return_tensors='pt'))\n"
            "print(tuple(output.last_hidden_state.shape))\n"
            "PY",
            timeout=900_000,
            allow_network=True,
        )

        workloads.run(
            "network-public-outbound",
            "set -eu; getent ahostsv4 example.com | head -1; "
            "curl -fsSL --max-time 30 https://example.com >/root/example.html; "
            "grep -qi example /root/example.html; "
            "curl -fsSL --max-time 30 -L http://example.com >/dev/null; "
            "cp /usr/bin/curl /root/copied-curl; /root/copied-curl -fsSL "
            "--max-time 30 https://example.com >/dev/null; "
            "python3 -c \"import subprocess; subprocess.run(["
            "'/root/copied-curl','-fsSL','--max-time','30',"
            "'https://example.com'], check=True, stdout=subprocess.DEVNULL)\"; "
            "dig +time=5 +tries=1 example.com A | grep -q 'status: NOERROR'",
            timeout=180_000,
            allow_network=True,
        )
        workloads.run(
            "network-local-denial",
            "python3 - <<'PY'\n"
            "import errno, socket\n"
            "for address, port in [('127.0.0.1', 8734), ('10.0.2.2', 8734)]:\n"
            "    sock = socket.socket()\n"
            "    try:\n"
            "        sock.settimeout(2); sock.connect((address, port))\n"
            "    except OSError as failure:\n"
            "        assert failure.errno in (errno.EACCES, errno.EPERM), failure\n"
            "    else:\n"
            "        raise AssertionError(address)\n"
            "    finally:\n"
            "        sock.close()\n"
            "listener = socket.socket()\n"
            "try:\n"
            "    listener.bind(('0.0.0.0', 0))\n"
            "except OSError as failure:\n"
            "    assert failure.errno in (errno.EACCES, errno.EPERM), failure\n"
            "else:\n"
            "    raise AssertionError('listener unexpectedly allowed')\n"
            "finally:\n"
            "    listener.close()\n"
            "PY",
            allow_network=True,
        )
        workloads.run(
            "network-disabled",
            "python3 - <<'PY'\n"
            "import errno, socket\n"
            "probes = [(socket.AF_INET, socket.SOCK_STREAM), "
            "(socket.AF_INET, socket.SOCK_DGRAM), "
            "(socket.AF_INET6, socket.SOCK_STREAM)]\n"
            "for family, kind in probes:\n"
            "    try:\n"
            "        socket.socket(family, kind)\n"
            "    except OSError as failure:\n"
            "        assert failure.errno in (errno.EACCES, errno.EPERM), failure\n"
            "    else:\n"
            "        raise AssertionError((family, kind))\n"
            "PY\n"
            "! curl -fsSL --max-time 5 https://example.com >/dev/null 2>&1; "
            "! /root/copied-curl -fsSL --max-time 5 "
            "https://example.com >/dev/null 2>&1",
        )

        client.adb_command("shell", "am", "force-stop", PACKAGE)
        client.adb_command(
            "shell", "am", "start", "-W", "-n", f"{PACKAGE}/.OrnamentActivity",
        )
        client.wait_until_ready()
        workloads.run(
            "restart-persistence",
            "set -eu; andock-apt-check; tree --version | head -1; "
            "python3 -c 'import requests, torch, transformers'; "
            "/root/venv/bin/python -c 'import idna'; "
            "cd /root/node-addon; "
            "node -e \"const a=require('./build/Release/answer'); "
            "if(a.answer()!==42) process.exit(1)\"; "
            "test \"$(find /root/many -type f | wc -l)\" -eq 10000; "
            "HF_HUB_OFFLINE=1 python3 - <<'PY'\n"
            "from transformers import AutoModel\n"
            "AutoModel.from_pretrained('hf-internal-testing/tiny-random-bert', "
            "local_files_only=True)\n"
            "PY",
            timeout=300_000,
        )
    finally:
        evidence_path = Path(arguments.evidence)
        evidence_path.parent.mkdir(parents=True, exist_ok=True)
        evidence_path.write_text(json.dumps({
            "serial": arguments.serial,
            "member": arguments.member,
            "total-seconds": round(time.monotonic() - run_started, 3),
            "commands": workloads.evidence,
        }, indent=2) + "\n")
        if not arguments.keep_member:
            try:
                client.request("destroy", arguments.member)
            except Exception:
                pass

    print("ANDOCK_EMULATOR_WORKLOADS_OK")


if __name__ == "__main__":
    main()
