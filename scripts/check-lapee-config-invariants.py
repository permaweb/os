#!/usr/bin/env python3
"""Check security invariants for shipped LapEE HyperBEAM config."""

from __future__ import annotations

import json
import pathlib
import sys
from typing import Any


ROOT = pathlib.Path(__file__).resolve().parents[1]
BASE_CONFIG = (
    ROOT
    / "arch"
    / "common"
    / "linux"
    / "buildroot-external"
    / "board"
    / "lapee"
    / "rootfs-overlay"
    / "etc"
    / "lapee"
    / "lapee.json"
)
INIT_SCRIPT = (
    ROOT
    / "arch"
    / "common"
    / "linux"
    / "buildroot-external"
    / "board"
    / "lapee"
    / "rootfs-overlay"
    / "init"
)
LINUX_ROOT = ROOT / "arch" / "common" / "linux" / "buildroot-external"
LINUX_DEFCONFIG = LINUX_ROOT / "configs" / "lapee_defconfig"
DOCKER_DEFCONFIG = LINUX_ROOT / "configs" / "lapee-docker.extra"
DOCKER_KERNEL_CONFIG = (
    LINUX_ROOT / "board" / "lapee" / "linux-docker-fragment.config"
)
DOCKER_RUNTIME_HOOK = (
    LINUX_ROOT / "board" / "lapee" / "files" / "docker-runtime-capability.sh"
)
POST_BUILD_SCRIPT = LINUX_ROOT / "board" / "lapee" / "post-build.sh"
MAKEFILE = ROOT / "Makefile"
DEVICE_LOADING_INTERNALS = (
    "forge-bootstrap",
    "load-remote-devices",
    "loaded-device-store",
    "preloaded-store",
)


def fail(path: pathlib.Path, message: str) -> None:
    print(f"{path}: {message}", file=sys.stderr)
    raise SystemExit(1)


def load(path: pathlib.Path) -> dict[str, Any]:
    try:
        data = json.loads(path.read_text())
    except json.JSONDecodeError as exc:
        fail(path, f"invalid JSON: {exc}")
    if not isinstance(data, dict):
        fail(path, "top-level config must be a JSON object")
    return data


def start_hooks(config: dict[str, Any]) -> list[Any]:
    hooks = config.get("on", {}).get("start")
    if hooks is None:
        return []
    if isinstance(hooks, list):
        return hooks
    return [hooks]


def is_measurement_boot_hook(hook: Any) -> bool:
    return (
        isinstance(hook, dict)
        and hook.get("device") == "measurement@1.0"
        and hook.get("path") == "boot"
        and hook.get("method") == "POST"
        and hook.get("measurement-body-source") == "hook-body"
    )


def is_zone_start_hook(hook: Any) -> bool:
    return (
        isinstance(hook, dict)
        and hook.get("device") == "zone@1.0"
        and hook.get("path") == "start"
        and hook.get("method") == "POST"
    )


def main() -> int:
    config = load(BASE_CONFIG)
    hooks = start_hooks(config)
    if not hooks:
        fail(BASE_CONFIG, "base config must define on.start")
    if not is_measurement_boot_hook(hooks[0]):
        fail(
            BASE_CONFIG,
            "first on.start hook must be measurement@1.0 boot POST over hook-body",
        )
    if not any(is_zone_start_hook(hook) for hook in hooks[1:]):
        fail(
            BASE_CONFIG,
            "base config must include zone@1.0 start POST after measurement",
        )
    if config.get("trusted-device-signers"):
        fail(BASE_CONFIG, "base config must not pin trusted remote device signers")
    for key in DEVICE_LOADING_INTERNALS:
        if key in config:
            fail(BASE_CONFIG, f"base config must not set {key}")
    init_text = INIT_SCRIPT.read_text()
    if '<<"measurement-body-source">>' not in init_text:
        fail(INIT_SCRIPT, "operator config validator must reserve measurement-body-source")
    for key in DEVICE_LOADING_INTERNALS:
        if f'<<"{key}">>' not in init_text:
            fail(INIT_SCRIPT, f"operator config validator must reserve {key}")
    if "UserStart ++ BaseStart" not in init_text:
        fail(INIT_SCRIPT, "operator on.start hooks must run before base hooks")
    if "maps:size(UserOn)" not in init_text:
        fail(INIT_SCRIPT, "operator on/* hooks must be merged even without on.start")
    if "run_capability_hooks boot-input /mnt/esp" not in init_text:
        fail(INIT_SCRIPT, "capability inputs must be read before boot-media detach")
    if "run_capability_hooks activate" not in init_text:
        fail(INIT_SCRIPT, "measured capabilities must activate before HyperBEAM")
    if "docker" in init_text.lower():
        fail(INIT_SCRIPT, "ordinary init must contain no Docker marker or runtime code")

    default_config = LINUX_DEFCONFIG.read_text()
    docker_config = DOCKER_DEFCONFIG.read_text()
    direct_options = (
        "BR2_PACKAGE_DOCKER_ENGINE=y",
        "BR2_PACKAGE_DOCKER_ENGINE_DOCKER_INIT_TINI=y",
        "BR2_PACKAGE_DOCKER_CLI=y",
    )
    for option in direct_options:
        if option in default_config:
            fail(LINUX_DEFCONFIG, f"ordinary Linux image must omit {option}")
        if option not in docker_config:
            fail(DOCKER_DEFCONFIG, f"Docker profile must enable {option}")
    if "QEMU" in docker_config or "KVM" in docker_config:
        fail(DOCKER_DEFCONFIG, "Docker profile must not select QEMU or KVM")

    kernel_config = DOCKER_KERNEL_CONFIG.read_text()
    for option in (
        "CONFIG_BPF_SYSCALL=y",
        "CONFIG_CGROUP_BPF=y",
        "CONFIG_CFS_BANDWIDTH=y",
        "CONFIG_BLK_DEV_THROTTLING=y",
    ):
        if option not in kernel_config:
            fail(DOCKER_KERNEL_CONFIG, f"Docker kernel must enable {option}")
    if "CONFIG_KVM" in kernel_config or "CONFIG_QEMU" in kernel_config:
        fail(DOCKER_KERNEL_CONFIG, "Docker kernel fragment must not enable KVM/QEMU")

    runtime_hook = DOCKER_RUNTIME_HOOK.read_text()
    if "tcp://" in runtime_hook:
        fail(DOCKER_RUNTIME_HOOK, "private Docker Engine must never listen on TCP")
    for required in (
        'cmdline_value lapee.docker',
        'DOCKER_RAMDISK=1 /usr/bin/dockerd',
        '--host "unix://$_docker_socket"',
        '--data-root "$_docker_root/data"',
        '--exec-root "$_docker_root/exec"',
        "_docker_root=/run/lapee/docker-runtime",
        '"$_docker_root/members"',
        '"$_docker_root/transfer"',
        "--icc=false",
        'Docker execution requires host swap to remain disabled',
        'docker load --input "$_docker_archive"',
        'rm -f "$_docker_archive"',
    ):
        if required not in runtime_hook:
            fail(DOCKER_RUNTIME_HOOK, f"missing runtime invariant: {required}")
    if "PERMAWEBOS_DOCKER_IMAGE" in runtime_hook:
        fail(DOCKER_RUNTIME_HOOK, "runtime hook must not supply a default image")

    makefile_text = MAKEFILE.read_text()
    for required in (
        "DOCKER    ?= 0",
        "lapee-buildroot-docker",
        "KERNEL_EXTRA_FRAGMENTS",
        "DEFCONFIG_EXTRA_SNIPPETS",
        "lapee.docker=enabled",
    ):
        if required not in makefile_text:
            fail(MAKEFILE, f"missing optional Docker composition: {required}")

    post_build_text = POST_BUILD_SCRIPT.read_text()
    if "ordinary rootfs remains Docker-free" not in post_build_text:
        fail(POST_BUILD_SCRIPT, "ordinary rootfs needs an explicit negative gate")
    if "forbidden guest KVM support" not in post_build_text:
        fail(POST_BUILD_SCRIPT, "Docker profile needs a no-KVM artifact gate")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
