#!/bin/sh
set -eu

fail() {
	printf 'andock-kernel-paths: %s\n' "$*" >&2
	exit 1
}

expect_denied() {
	"$@" >/dev/null 2>&1 && fail "unexpected access: $*"
	return 0
}

mode=${1:-all}
marker=/dev/shm/andock-kernel-paths.marker

mkdir -p /root
cd /root

[ "$(readlink /proc/self/root)" = / ] || fail '/proc/self/root is not guest /'
[ "$(readlink /proc/thread-self/root)" = / ] ||
	fail '/proc/thread-self/root is not guest /'
[ "$(readlink /proc/self/cwd)" = "$(pwd -P)" ] ||
	fail '/proc/self/cwd does not report the guest cwd'
case $(readlink /proc/self/exe) in
	/*) ;;
	*) fail '/proc/self/exe does not report a guest path' ;;
esac
for attempt in 1 2 3; do
	[ "$(sh -c 'readlink /proc/self/root')" = / ] ||
		fail "nested exec lost the guest root on attempt $attempt"
done

python3 - <<'PY'
from multiprocessing import Process, Queue
import ctypes
import os
import stat
import struct

libc = ctypes.CDLL(None, use_errno=True)
libc.syscall.restype = ctypes.c_long

for proc_directory, required in (
    ("/proc/self", {"fd", "cwd", "exe", "root"}),
    ("/proc/self/fd", {"0", "1", "2"}),
    ("/dev/fd", {"0", "1", "2"}),
):
    descriptor = os.open(proc_directory, os.O_RDONLY | os.O_DIRECTORY)
    opened = os.fstat(descriptor)
    named = os.stat(proc_directory)
    assert stat.S_ISDIR(opened.st_mode)
    assert (opened.st_dev, opened.st_ino) == (named.st_dev, named.st_ino)
    assert required <= set(os.listdir(descriptor))

    fstatat = ctypes.create_string_buffer(256)
    assert libc.syscall(
        ctypes.c_long(79),
        ctypes.c_int(descriptor),
        ctypes.c_char_p(b""),
        ctypes.byref(fstatat),
        ctypes.c_int(0x1000),
    ) == 0, (proc_directory, ctypes.get_errno())
    device, inode = struct.unpack_from("=QQ", fstatat)
    mode = struct.unpack_from("=I", fstatat, 16)[0]
    assert stat.S_ISDIR(mode)
    assert (device, inode) == (named.st_dev, named.st_ino)

    statx = ctypes.create_string_buffer(256)
    assert libc.syscall(
        ctypes.c_long(291),
        ctypes.c_int(descriptor),
        ctypes.c_char_p(b""),
        ctypes.c_int(0x1000),
        ctypes.c_uint(0x7ff),
        ctypes.byref(statx),
    ) == 0, (proc_directory, ctypes.get_errno())
    statx_mode = struct.unpack_from("=H", statx, 28)[0]
    statx_inode = struct.unpack_from("=Q", statx, 32)[0]
    statx_device = os.makedev(
        struct.unpack_from("=I", statx, 136)[0],
        struct.unpack_from("=I", statx, 140)[0],
    )
    assert stat.S_ISDIR(statx_mode)
    assert (statx_device, statx_inode) == (named.st_dev, named.st_ino)
    os.close(descriptor)

path = "/etc/os-release"
with open(path, "rb") as first:
    prefix = first.read(32)
    assert prefix
    with open(path, "rb") as second:
        assert second.read(32) == prefix
    first.seek(0)
    assert first.read(32) == prefix

path = "/root/andock-open-coherence"
with open(path, "w+b") as first:
    first.write(b"abcdef")
    first.flush()
    with open(path, "r+b") as second:
        assert second.read() == b"abcdef"
        second.seek(2)
        second.write(b"XY")
        second.flush()
    first.seek(0)
    assert first.read() == b"abXYef"

def read_copy(output):
    with open(path, "rb") as handle:
        output.put(handle.read())

output = Queue()
workers = [Process(target=read_copy, args=(output,)) for _ in range(2)]
for worker in workers:
    worker.start()
for worker in workers:
    worker.join()
    assert worker.exitcode == 0
assert sorted(output.get() for _ in workers) == [b"abXYef", b"abXYef"]
PY
ls -la /proc/self/fd >/dev/null
ls -la /dev/fd >/dev/null
rm /root/andock-open-coherence

printf 'guest-root\n' >/root/andock-kernel-paths.root
[ "$(cat /proc/self/root/root/andock-kernel-paths.root)" = guest-root ] ||
	fail '/proc/self/root suffix did not resolve inside the guest'
rm /root/andock-kernel-paths.root

expect_denied cat /proc/self/environ
expect_denied cat /proc/self/maps
expect_denied cat /proc/self/mountinfo
expect_denied cat /proc/mounts
expect_denied ls /proc/1
expect_denied ls /sys
for cpu_identity in \
	/sys/devices/system/cpu/possible \
	/sys/devices/system/cpu/present \
	/sys/devices/system/cpu/cpu0/regs/identification/midr_el1; do
	[ -n "$(cat "$cpu_identity")" ] ||
		fail "empty CPU identity file: $cpu_identity"
	expect_denied sh -c "printf forged >'$cpu_identity'"
done
expect_denied cat /dev/kmsg
expect_denied ls /dev/block
expect_denied readlink /proc/self/fd/987
expect_denied cat /data/local/tmp/andock-host-secret
expect_denied cat /proc/self/root/data/local/tmp/andock-host-secret
if [ -n "${ANDOCK_FORBIDDEN_PATH:-}" ]; then
	expect_denied cat "$ANDOCK_FORBIDDEN_PATH"
	expect_denied cat "/proc/self/root$ANDOCK_FORBIDDEN_PATH"
fi
if [ -n "${ANDOCK_FORBIDDEN_FD:-}" ]; then
	expect_denied readlink "/proc/self/fd/$ANDOCK_FORBIDDEN_FD"
	if ls -1 /proc/self/fd | grep -qx "$ANDOCK_FORBIDDEN_FD"; then
		fail "inherited supervisor fd $ANDOCK_FORBIDDEN_FD was enumerated"
	fi
fi
for standard_fd in 0 1 2; do
	if ! ls -1 /proc/self/fd | grep -qx "$standard_fd"; then
		fail "standard fd $standard_fd was not enumerated"
	fi
done
exec 7</etc/os-release
[ "$(readlink /proc/self/fd/7)" = "$(readlink -f /etc/os-release)" ] ||
	fail 'tracked guest fd did not expose its guest path'
ls -1 /proc/self/fd | grep -qx 7 ||
	fail 'tracked guest fd was not enumerated'
exec 7<&-

printf 'discarded' >/dev/null
printf 'andock-stdout-reopen\n' >/dev/stdout
printf 'andock-stderr-reopen\n' >/dev/stderr
printf 'andock-devfd-reopen\n' >/dev/fd/1
printf 'andock-devfd-stderr-reopen\n' >/dev/fd/2
printf 'andock-procfd-reopen\n' >/proc/self/fd/1
printf 'andock-procfd-stderr-reopen\n' >/proc/self/fd/2
printf 'andock-thread-procfd-reopen\n' >/proc/thread-self/fd/1
printf 'andock-thread-procfd-stderr-reopen\n' >/proc/thread-self/fd/2
[ "$(printf dev-stdin | cat /dev/stdin)" = dev-stdin ] ||
	fail '/dev/stdin did not reopen standard input'
[ "$(printf devfd-stdin | cat /dev/fd/0)" = devfd-stdin ] ||
	fail '/dev/fd/0 did not reopen standard input'
[ "$(printf procfd-stdin | cat /proc/self/fd/0)" = procfd-stdin ] ||
	fail '/proc/self/fd/0 did not reopen standard input'
[ "$(printf thread-procfd-stdin | cat /proc/thread-self/fd/0)" = thread-procfd-stdin ] ||
	fail '/proc/thread-self/fd/0 did not reopen standard input'
python3 - <<'PY'
import errno
import fcntl
import os

for path, access in (
    ("/dev/stdin", os.O_RDONLY),
    ("/dev/stdout", os.O_WRONLY),
    ("/dev/stderr", os.O_WRONLY),
    ("/dev/fd/0", os.O_RDONLY),
    ("/dev/fd/1", os.O_WRONLY),
    ("/dev/fd/2", os.O_WRONLY),
    ("/proc/self/fd/0", os.O_RDONLY),
    ("/proc/self/fd/1", os.O_WRONLY),
    ("/proc/self/fd/2", os.O_WRONLY),
    ("/proc/thread-self/fd/0", os.O_RDONLY),
    ("/proc/thread-self/fd/1", os.O_WRONLY),
    ("/proc/thread-self/fd/2", os.O_WRONLY),
):
    descriptor = os.open(path, access | os.O_CLOEXEC)
    try:
        assert fcntl.fcntl(descriptor, fcntl.F_GETFD) & fcntl.FD_CLOEXEC
    finally:
        os.close(descriptor)

for path, flags in (
    ("/dev/stdin", os.O_WRONLY),
    ("/dev/stdout", os.O_RDONLY),
    ("/dev/stderr", os.O_WRONLY | os.O_APPEND),
):
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        assert error.errno == errno.EOPNOTSUPP, error
    else:
        os.close(descriptor)
        raise AssertionError((path, flags, "unsupported reopen succeeded"))
PY
[ "$(dd if=/dev/zero bs=8 count=1 2>/dev/null | wc -c)" -eq 8 ] ||
	fail '/dev/zero did not return zero bytes'
[ "$(dd if=/dev/random bs=8 count=1 2>/dev/null | wc -c)" -eq 8 ] ||
	fail '/dev/random did not return bytes'
[ "$(dd if=/dev/urandom bs=8 count=1 2>/dev/null | wc -c)" -eq 8 ] ||
	fail '/dev/urandom did not return bytes'
if printf x >/dev/full 2>/dev/null; then
	fail '/dev/full accepted a write'
fi

case $mode in
	write)
		printf 'persistent-shm\n' >"$marker"
		python3 - <<'PY'
import errno
import fcntl
import os
import stat


def expect_open_error(path, flags, expected):
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        assert error.errno == expected, (error.errno, expected)
    else:
        os.close(descriptor)
        raise AssertionError((path, flags, "open unexpectedly succeeded"))

path = "/root/andock-procfd-persist"
with open(path, "w+b", buffering=0) as original:
    original.write(b"abcdef")
    original.seek(2)
    proc_path = f"/proc/self/fd/{original.fileno()}"
    expect_open_error(proc_path, os.O_RDONLY | os.O_NOFOLLOW, errno.ELOOP)
    if hasattr(os, "O_PATH"):
        # Synthetic proc links do not currently expose link-inode O_PATH FDs.
        expect_open_error(
            proc_path,
            os.O_PATH | os.O_NOFOLLOW,
            errno.EOPNOTSUPP,
        )
    expect_open_error(proc_path, os.O_RDONLY | os.O_DIRECTORY, errno.ENOTDIR)
    reopened = os.open(
        proc_path,
        os.O_RDWR | os.O_APPEND,
    )
    assert original.tell() == 2
    assert fcntl.fcntl(reopened, fcntl.F_GETFL) & os.O_APPEND
    assert not (fcntl.fcntl(original, fcntl.F_GETFL) & os.O_APPEND)
    os.write(reopened, b"!")
    assert original.tell() == 2
    assert os.lseek(reopened, 0, os.SEEK_CUR) == 7
    fcntl.fcntl(
        reopened,
        fcntl.F_SETFL,
        fcntl.fcntl(reopened, fcntl.F_GETFL) & ~os.O_APPEND,
    )
    os.lseek(reopened, 1, os.SEEK_SET)
    os.write(reopened, b"Z")
    os.close(reopened)

    proc_directory = os.open("/proc/self/fd", os.O_RDONLY | os.O_DIRECTORY)
    try:
        proc_directory_path = f"/proc/self/fd/{proc_directory}"
        reopened_directory = os.open(
            proc_directory_path,
            os.O_RDONLY | os.O_DIRECTORY,
        )
        assert stat.S_ISDIR(os.fstat(reopened_directory).st_mode)
        os.close(reopened_directory)
        expect_open_error(proc_directory_path, os.O_WRONLY, errno.EISDIR)
        expect_open_error(
            proc_directory_path,
            os.O_RDONLY | os.O_TRUNC,
            errno.EISDIR,
        )
        descriptor = str(original.fileno())
        assert os.readlink(descriptor, dir_fd=proc_directory) == path
        followed = os.stat(descriptor, dir_fd=proc_directory)
        link = os.stat(
            descriptor,
            dir_fd=proc_directory,
            follow_symlinks=False,
        )
        assert followed.st_size == 7
        assert stat.S_ISLNK(link.st_mode)
        relative = os.open(descriptor, os.O_RDWR, dir_fd=proc_directory)
        os.lseek(relative, 3, os.SEEK_SET)
        os.write(relative, b"Q")
        os.close(relative)
    finally:
        os.close(proc_directory)
    assert original.tell() == 2
    original.seek(0)
    assert original.read() == b"aZcQef!"
    truncated = os.open(
        f"/proc/self/fd/{original.fileno()}",
        os.O_WRONLY | os.O_TRUNC,
    )
    os.write(truncated, b"persisted")
    os.close(truncated)
    original.seek(0)
    assert original.read() == b"persisted"

unlinked = "/root/andock-procfd-unlinked"
original = os.open(unlinked, os.O_CREAT | os.O_RDWR | os.O_TRUNC, 0o600)
os.write(original, b"still-open")
os.unlink(unlinked)
reopened = os.open(f"/proc/self/fd/{original}", os.O_RDWR)
os.close(original)
assert os.read(reopened, len(b"still-open")) == b"still-open"
os.write(reopened, b"!")
os.lseek(reopened, 0, os.SEEK_SET)
assert os.read(reopened, len(b"still-open!")) == b"still-open!"
os.close(reopened)
assert not os.path.exists(unlinked)
PY
		;;
	verify)
		[ "$(cat "$marker")" = persistent-shm ] ||
			fail '/dev/shm marker did not persist across process restart'
		rm "$marker"
		[ "$(cat /root/andock-procfd-persist)" = persisted ] ||
			fail 'proc-fd reopen writes did not persist across restart'
		[ ! -e /root/andock-procfd-unlinked ] ||
			fail 'open-unlinked proc-fd path reappeared after restart'
		rm /root/andock-procfd-persist
		;;
	all)
		work=/dev/shm/andock-kernel-paths.$$
		mkdir "$work"
		printf 'atomic\n' >"$work/source"
		mv "$work/source" "$work/renamed"
		[ "$(cat "$work/renamed")" = atomic ] ||
			fail '/dev/shm create or rename failed'
		rm -rf "$work"
		python3 - <<'PY'
import errno
import fcntl
import multiprocessing
import os
from multiprocessing import shared_memory

segment = shared_memory.SharedMemory(create=True, size=32)
try:
    segment.buf[:6] = b"andock"
    assert bytes(segment.buf[:6]) == b"andock"
finally:
    segment.close()
    segment.unlink()

first = os.open("/root/andock-blocking-flock", os.O_CREAT | os.O_RDWR, 0o644)
second = os.open("/root/andock-blocking-flock", os.O_RDWR)
fcntl.flock(first, fcntl.LOCK_EX | fcntl.LOCK_NB)
try:
    fcntl.flock(second, fcntl.LOCK_EX)
except OSError as failure:
    assert failure.errno == errno.EOPNOTSUPP, failure
else:
    raise AssertionError("unsupported blocking flock unexpectedly succeeded")
fcntl.flock(first, fcntl.LOCK_UN)
os.close(second)
os.close(first)
os.unlink("/root/andock-blocking-flock")

def append_with_iov(label):
    descriptor = os.open(
        "/root/andock-writev-append",
        os.O_CREAT | os.O_WRONLY | os.O_APPEND,
        0o644,
    )
    for index in range(50):
        os.writev(descriptor, [f"{label}:".encode(), f"{index}\n".encode()])
    os.close(descriptor)

workers = [
    multiprocessing.get_context("fork").Process(
        target=append_with_iov,
        args=(label,),
    )
    for label in ("a", "b")
]
for worker in workers:
    worker.start()
for worker in workers:
    worker.join()
    assert worker.exitcode == 0
with open("/root/andock-writev-append") as appended:
    lines = appended.read().splitlines()
assert len(lines) == len(set(lines)) == 100
os.unlink("/root/andock-writev-append")
PY
		;;
	*) fail "unknown mode: $mode" ;;
esac

printf 'ANDOCK_KERNEL_PATHS_OK mode=%s\n' "$mode"
