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

    def run(
        self,
        name,
        command,
        timeout=30_000,
        allow_network=False,
        expect=0,
        maximum_seconds=None,
    ):
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
        if maximum_seconds is not None:
            require(
                elapsed <= maximum_seconds,
                f"{name}: {elapsed:.3f}s exceeded {maximum_seconds:.3f}s",
            )
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
            "cmake dnsutils espeak-ng ffmpeg golang-go "
            "netcat-openbsd openjdk-21-jdk-headless pkg-config rustc cargo "
            "strace tree; "
            "printf '#!/bin/sh\\nprintf andock-apt-ok\\n' "
            ">/usr/local/bin/andock-apt-check; "
            "chmod 0755 /usr/local/bin/andock-apt-check; "
            "andock-apt-check; dpkg-query -W dnsutils tree",
            timeout=900_000,
            allow_network=True,
        )

        workloads.write(
            "/root/toolchains/main.c",
            "#include <stdio.h>\nint main(void) { puts(\"c=42\"); return 0; }\n",
        )
        workloads.write(
            "/root/toolchains/main.cc",
            "#include <iostream>\nint main() { std::cout << \"cxx=42\\n\"; }\n",
        )
        workloads.write(
            "/root/toolchains/CMakeLists.txt",
            "cmake_minimum_required(VERSION 3.16)\n"
            "project(andock C)\nadd_executable(cmake-main main.c)\n",
        )
        workloads.write(
            "/root/toolchains/main.go",
            "package main\nimport \"fmt\"\nfunc main() { fmt.Println(\"go=42\") }\n",
        )
        workloads.write(
            "/root/toolchains/main.rs",
            "fn main() { println!(\"rust=42\"); }\n",
        )
        workloads.write(
            "/root/toolchains/Main.java",
            "class Main { public static void main(String[] args) { "
            "System.out.println(\"java=42\"); } }\n",
        )
        workloads.run(
            "installed-toolchains",
            "set -eu; cd /root/toolchains; "
            "cc -O2 -o c-main main.c; ./c-main | grep -qx c=42; "
            "c++ -O2 -o cxx-main main.cc; ./cxx-main | grep -qx cxx=42; "
            "cmake -S . -B build >/dev/null; "
            "cmake --build build >/dev/null; ./build/cmake-main | grep -qx c=42; "
            "go build -o go-main main.go; ./go-main | grep -qx go=42; "
            "rustc -O -o rust-main main.rs; ./rust-main | grep -qx rust=42; "
            "javac Main.java; java Main | grep -qx java=42; "
            "espeak-ng -w /root/andock.wav 'Andock on Android'; "
            "ffmpeg -loglevel error -y -i /root/andock.wav /root/andock.flac; "
            "file /root/andock.wav /root/andock.flac",
            timeout=600_000,
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
            "/root/py-native/setup.py",
            "from setuptools import Extension, setup\n"
            "setup(name='andock-native', version='1.0', "
            "ext_modules=[Extension('andock_native', ['andock_native.c'])])\n",
        )
        workloads.write(
            "/root/py-native/andock_native.c",
            "#define PY_SSIZE_T_CLEAN\n#include <Python.h>\n"
            "static PyObject *answer(PyObject *self, PyObject *args) { "
            "return PyLong_FromLong(42); }\n"
            "static PyMethodDef methods[] = {{\"answer\", answer, METH_NOARGS, \"\"}, "
            "{NULL, NULL, 0, NULL}};\n"
            "static struct PyModuleDef module = {PyModuleDef_HEAD_INIT, "
            "\"andock_native\", NULL, -1, methods};\n"
            "PyMODINIT_FUNC PyInit_andock_native(void) { "
            "return PyModule_Create(&module); }\n",
        )
        workloads.run(
            "pip-user-wheel-native-extension",
            "set -eu; "
            "pip install --user --no-cache-dir --disable-pip-version-check "
            "/root/py-native; "
            "python3 -c 'import andock_native; assert andock_native.answer() == 42'; "
            "mkdir -p /root/wheels; "
            "pip wheel --no-cache-dir --disable-pip-version-check "
            "--wheel-dir /root/wheels /root/py-native; "
            "/root/venv/bin/pip install --force-reinstall /root/wheels/*.whl; "
            "/root/venv/bin/python -c "
            "'import andock_native; assert andock_native.answer() == 42'; "
            "pip check",
            timeout=600_000,
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
            "test \"$(find /root/many -maxdepth 1 -type f | wc -l)\" "
            "-eq 10000; "
            "du -sh /root/many",
            timeout=600_000,
        )
        workloads.run(
            "git-large-tree",
            "set -eu; cd /root/many; git init -q; "
            "git config user.name Andock; "
            "git config user.email andock@localhost; "
            "git add .; git commit -qm initial; "
            "test -z \"$(git status --porcelain)\"; "
            "printf changed >00042; "
            "git diff --exit-code --quiet && exit 1 || test $? -eq 1; "
            "git diff --numstat | grep -q '^1[[:space:]]1[[:space:]]00042$'; "
            "git status --porcelain | grep -q '^ M 00042$'",
            timeout=600_000,
        )
        workloads.run(
            "sqlite-and-archives",
            "set -eu; "
            "sqlite3 /root/test.db "
            "\"create table numbers(n integer); "
            "with recursive c(n) as (values(1) union all select n+1 from c "
            "where n<1000) insert into numbers select n from c;\"; "
            "test \"$(sqlite3 /root/test.db 'select sum(n) from numbers')\" "
            "= 500500; "
            "tar -C /root -cJf /root/many.tar.xz many; "
            "mkdir /root/unpacked; tar -C /root/unpacked -xJf /root/many.tar.xz; "
            "test \"$(find /root/unpacked/many -type f | wc -l)\" -ge 10000; "
            "python3 -m zipfile -c /root/many.zip /root/many/00000 "
            "/root/many/09999; unzip -t /root/many.zip >/dev/null",
            timeout=600_000,
        )
        workloads.run(
            "linux-ipc-and-mmap",
            "set -eu; python3 - <<'PY'\n"
            "from multiprocessing import shared_memory\n"
            "import mmap\n"
            "shared = shared_memory.SharedMemory(create=True, size=32)\n"
            "shared.buf[:4] = b'good'\n"
            "assert bytes(shared.buf[:4]) == b'good'\n"
            "shared.close(); shared.unlink()\n"
            "with open('/root/mmap-data', 'w+b') as output:\n"
            "    output.truncate(4096)\n"
            "    with mmap.mmap(output.fileno(), 4096) as mapped:\n"
            "        mapped[:4] = b'mmap'; mapped.flush()\n"
            "PY\n"
            "test \"$(head -c 4 /root/mmap-data)\" = mmap",
        )
        unix_semantics = (
            Path(__file__).parent.parent
            / "execution/tests/andock_unix_semantics.py"
        ).read_text()
        workloads.write("/root/andock_unix_semantics.py", unix_semantics)
        workloads.run(
            "linux-umask-and-unix-sockets",
            "python3 /root/andock_unix_semantics.py",
            timeout=300_000,
        )
        semantics = (
            Path(__file__).parent.parent
            / "execution/tests/andock_linux_semantics.py"
        ).read_text()
        workloads.write("/root/andock_linux_semantics.py", semantics)
        workloads.run(
            "linux-file-syscalls",
            "python3 /root/andock_linux_semantics.py",
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
        for index in range(1, 4):
            workloads.run(
                f"python-ml-warm-{index}",
                "set -eu; "
                "python3 -c 'import torch; print(torch.__version__)' >/dev/null; "
                "pip3 show torch >/dev/null; "
                "du -sh /root/.local "
                "/usr/local/lib/python3.12/dist-packages >/dev/null",
                maximum_seconds=10,
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
            "unix-socket-restart",
            "python3 - <<'PY'\n"
            "import errno, os, socket, stat\n"
            "path = '/root/andock-stale.sock'\n"
            "assert stat.S_ISSOCK(os.lstat(path).st_mode)\n"
            "client = socket.socket(socket.AF_UNIX)\n"
            "try:\n"
            "    client.connect(path)\n"
            "except OSError as failure:\n"
            "    assert failure.errno == errno.ECONNREFUSED, failure\n"
            "else:\n"
            "    raise AssertionError('stale socket unexpectedly connected')\n"
            "finally:\n"
            "    client.close()\n"
            "os.unlink(path)\n"
            "replacement = socket.socket(socket.AF_UNIX)\n"
            "replacement.bind(path); replacement.close()\n"
            "os.unlink(path)\n"
            "PY",
        )
        workloads.run(
            "restart-persistence",
            "set -eu; andock-apt-check; tree --version | head -1; "
            "python3 -c 'import andock_native, requests, torch, transformers; "
            "assert andock_native.answer() == 42'; "
            "/root/venv/bin/python -c 'import andock_native, idna; "
            "assert andock_native.answer() == 42'; "
            "cd /root/node-addon; "
            "node -e \"const a=require('./build/Release/answer'); "
            "if(a.answer()!==42) process.exit(1)\"; "
            "test \"$(find /root/many -maxdepth 1 -type f | wc -l)\" "
            "-eq 10000; "
            "test \"$(sqlite3 /root/test.db 'select sum(n) from numbers')\" "
            "= 500500; "
            "/root/toolchains/c-main | grep -qx c=42; "
            "/root/toolchains/go-main | grep -qx go=42; "
            "/root/toolchains/rust-main | grep -qx rust=42; "
            "test -s /root/andock.wav -a -s /root/andock.flac; "
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
