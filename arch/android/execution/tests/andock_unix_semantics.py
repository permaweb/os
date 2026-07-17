#!/usr/bin/env python3

import errno
import os
from pathlib import Path
import shutil
import socket
import stat
import sys
import threading


ROOT = Path(os.environ.get("ANDOCK_UNIX_TEST_ROOT", "/root/andock-unix-semantics"))
STALE_PATH = ROOT.parent / "andock-stale.sock"


def mode(path):
    return stat.S_IMODE(os.lstat(path).st_mode)


def expect_error(expected, operation):
    try:
        operation()
    except OSError as failure:
        assert failure.errno in expected, failure
    else:
        raise AssertionError(f"expected one of {sorted(expected)}")


def remove(path):
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass


shutil.rmtree(ROOT, ignore_errors=True)
ROOT.mkdir()

# Creation modes must use the guest filesystem context, not Android's host
# umask or the raw mode argument presented to the traced syscall.
os.umask(0o077)
(ROOT / "private-file").touch()
(ROOT / "private-dir").mkdir()
assert mode(ROOT / "private-file") == 0o600
assert mode(ROOT / "private-dir") == 0o700

os.umask(0o027)
(ROOT / "group-file").touch()
(ROOT / "group-dir").mkdir()
assert mode(ROOT / "group-file") == 0o640
assert mode(ROOT / "group-dir") == 0o750

# fork(2) copies the fs context when CLONE_FS is absent. A child changing its
# umask must not mutate the parent's copy.
pid = os.fork()
if pid == 0:
    os.umask(0o077)
    (ROOT / "child-file").touch()
    os._exit(0)
_, wait_status = os.waitpid(pid, 0)
assert os.waitstatus_to_exitcode(wait_status) == 0
(ROOT / "parent-file").touch()
assert mode(ROOT / "child-file") == 0o600
assert mode(ROOT / "parent-file") == 0o640

# A pathname socket is a real persistent filesystem node. Existing streams
# survive unlink; pathname lookup does not. Rebinding the pathname creates a
# new socket generation without disturbing the old server.
stream_path = str(ROOT / "stream.sock")
os.umask(0o077)
old_server = socket.socket(socket.AF_UNIX)
old_server.bind(stream_path)
assert old_server.getsockname() == stream_path
assert stat.S_ISSOCK(os.lstat(stream_path).st_mode)
assert mode(stream_path) == 0o700
expect_error({errno.EADDRINUSE}, lambda: socket.socket(socket.AF_UNIX).bind(stream_path))
old_server.listen()
old_client = socket.socket(socket.AF_UNIX)
old_client.connect(stream_path)
old_peer, _ = old_server.accept()
old_client.sendall(b"old-before-unlink")
assert old_peer.recv(64) == b"old-before-unlink"
os.unlink(stream_path)
assert not os.path.lexists(stream_path)
old_client.sendall(b"old-after-unlink")
assert old_peer.recv(64) == b"old-after-unlink"
missing_client = socket.socket(socket.AF_UNIX)
expect_error({errno.ENOENT}, lambda: missing_client.connect(stream_path))
missing_client.close()

os.umask(0o027)
new_server = socket.socket(socket.AF_UNIX)
new_server.bind(stream_path)
assert new_server.getsockname() == stream_path
assert old_server.getsockname() == stream_path
assert mode(stream_path) == 0o750
new_server.listen()
new_client = socket.socket(socket.AF_UNIX)
new_client.connect(stream_path)
new_peer, _ = new_server.accept()
new_client.sendall(b"new-generation")
assert new_peer.recv(64) == b"new-generation"
new_peer.close()
new_client.close()
new_server.close()
assert stat.S_ISSOCK(os.lstat(stream_path).st_mode)
refused_client = socket.socket(socket.AF_UNIX)
expect_error({errno.ECONNREFUSED}, lambda: refused_client.connect(stream_path))
refused_client.close()
os.unlink(stream_path)
old_peer.close()
old_client.close()
old_server.close()

# If the kernel rejects bind after the guest node was reserved, rollback must
# remove exactly that reservation so a fresh socket can bind the same path.
first_path = str(ROOT / "first.sock")
retry_path = str(ROOT / "retry.sock")
already_bound = socket.socket(socket.AF_UNIX)
already_bound.bind(first_path)
expect_error(
    {errno.EINVAL, errno.EADDRINUSE},
    lambda: already_bound.bind(retry_path),
)
assert not os.path.lexists(retry_path)
retry = socket.socket(socket.AF_UNIX)
retry.bind(retry_path)
retry.close()
already_bound.close()
os.unlink(first_path)
os.unlink(retry_path)

# Simultaneous binds must have one winner and one EADDRINUSE loser, never two
# live abstract generations behind one visible node.
for iteration in range(32):
    race_path = str(ROOT / f"race-{iteration}.sock")
    barrier = threading.Barrier(3)
    outcomes = []
    lock = threading.Lock()

    def bind_racer():
        candidate = socket.socket(socket.AF_UNIX)
        barrier.wait()
        try:
            candidate.bind(race_path)
        except OSError as failure:
            outcome = failure.errno
        else:
            outcome = 0
        with lock:
            outcomes.append((outcome, candidate))

    racers = [threading.Thread(target=bind_racer) for _ in range(2)]
    for racer in racers:
        racer.start()
    barrier.wait()
    for racer in racers:
        racer.join()
    results = sorted(result for result, _ in outcomes)
    if sys.platform == "darwin":
        assert results[0] == 0 and results[1] in {errno.EEXIST, errno.EADDRINUSE}
    else:
        assert results == [0, errno.EADDRINUSE]
    for _, candidate in outcomes:
        candidate.close()
    os.unlink(race_path)

# Relative paths and a final symlink behave like the host Linux pathname
# namespace: bind creates the target node, and connect follows the link.
relative_dir = ROOT / "relative"
relative_dir.mkdir()
original_cwd = os.getcwd()
os.chdir(relative_dir)
os.symlink("target.sock", "link.sock")
relative_server = socket.socket(socket.AF_UNIX)
relative_server.bind("link.sock")
relative_server.listen()
assert os.path.islink("link.sock")
assert stat.S_ISSOCK(os.lstat("target.sock").st_mode)
relative_client = socket.socket(socket.AF_UNIX)
relative_client.connect("link.sock")
relative_peer, _ = relative_server.accept()
relative_client.sendall(b"relative")
assert relative_peer.recv(64) == b"relative"
relative_peer.close()
relative_client.close()
relative_server.close()
os.unlink("target.sock")
os.unlink("link.sock")
os.chdir(original_cwd)

# Datagram source addresses must be detranslated back to guest paths.
datagram_a_path = str(ROOT / "datagram-a.sock")
datagram_b_path = str(ROOT / "datagram-b.sock")
datagram_a = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
datagram_b = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
datagram_a.bind(datagram_a_path)
datagram_b.bind(datagram_b_path)
datagram_a.sendto(b"datagram", datagram_b_path)
payload, source = datagram_b.recvfrom(64)
assert payload == b"datagram"
assert source == datagram_a_path
datagram_a.close()
datagram_b.close()
os.unlink(datagram_a_path)
os.unlink(datagram_b_path)

if sys.platform == "linux" and hasattr(socket, "SOCK_SEQPACKET"):
    seqpacket_path = str(ROOT / "seqpacket.sock")
    seqpacket_server = socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET)
    seqpacket_server.bind(seqpacket_path)
    seqpacket_server.listen()
    seqpacket_client = socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET)
    seqpacket_client.connect(seqpacket_path)
    seqpacket_peer, _ = seqpacket_server.accept()
    seqpacket_client.send(b"seqpacket")
    assert seqpacket_peer.recv(64) == b"seqpacket"
    seqpacket_peer.close()
    seqpacket_client.close()
    seqpacket_server.close()
    os.unlink(seqpacket_path)

# Abstract sockets remain kernel-only and do not create ext4 nodes.
if sys.platform == "linux":
    abstract_name = f"\0andock-{os.getpid()}"
    abstract_server = socket.socket(socket.AF_UNIX)
    abstract_server.bind(abstract_name)
    abstract_server.listen()
    abstract_client = socket.socket(socket.AF_UNIX)
    abstract_client.connect(abstract_name)
    abstract_peer, _ = abstract_server.accept()
    abstract_client.sendall(b"abstract")
    assert abstract_peer.recv(64) == b"abstract"
    abstract_peer.close()
    abstract_client.close()
    abstract_server.close()

# Leave a closed pathname node for the service-restart test. A later PRoot
# process must observe the node and return ECONNREFUSED, then permit unlink and
# rebind.
stale_path = str(STALE_PATH)
remove(stale_path)
stale = socket.socket(socket.AF_UNIX)
stale.bind(stale_path)
stale.close()
assert stat.S_ISSOCK(os.lstat(stale_path).st_mode)

print("ANDOCK_UNIX_SEMANTICS_OK")
