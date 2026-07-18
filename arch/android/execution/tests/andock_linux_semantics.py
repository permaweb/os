import errno
import fcntl
import multiprocessing
import os


source_data = bytes(range(256)) * 4096
with open("/root/syscall-source", "wb") as output:
    output.write(source_data)

source = os.open("/root/syscall-source", os.O_RDONLY)
independent = os.open("/root/syscall-source", os.O_RDONLY)
destination = os.open("/root/sendfile-copy", os.O_CREAT | os.O_RDWR, 0o644)
os.lseek(source, 123, os.SEEK_SET)
assert os.sendfile(destination, source, None, 65536) == 65536
assert os.lseek(source, 0, os.SEEK_CUR) == 65659
assert os.lseek(independent, 0, os.SEEK_CUR) == 0
assert os.pread(destination, 65536, 0) == source_data[123:65659]
os.close(destination)
os.close(independent)
os.close(source)

source = os.open("/root/syscall-source", os.O_RDONLY)
destination = os.open("/root/copy-range", os.O_CREAT | os.O_RDWR, 0o644)
assert os.copy_file_range(source, destination, 131072) == 131072
assert os.pread(destination, 131072, 0) == source_data[:131072]
os.close(destination)
os.close(source)

source = os.open("/root/syscall-source", os.O_RDONLY)
destination = os.open("/root/splice-copy", os.O_CREAT | os.O_RDWR, 0o644)
reader, writer = os.pipe()
assert os.splice(source, writer, 65536) == 65536
assert os.splice(reader, destination, 65536) == 65536
assert os.pread(destination, 65536, 0) == source_data[:65536]
for descriptor in (reader, writer, destination, source):
    os.close(descriptor)

allocated = os.open("/root/fallocate", os.O_CREAT | os.O_RDWR, 0o644)
os.posix_fallocate(allocated, 0, 1024 * 1024)
assert os.fstat(allocated).st_size == 1024 * 1024
assert os.pread(allocated, 16, 512 * 1024) == bytes(16)
os.close(allocated)
readonly = os.open("/root/fallocate", os.O_RDONLY)
try:
    os.posix_fallocate(readonly, 0, 2 * 1024 * 1024)
except OSError as failure:
    assert failure.errno == errno.EBADF, failure
else:
    raise AssertionError("read-only fallocate succeeded")
os.close(readonly)

xattr_path = "/root/xattr-metadata"
with open(xattr_path, "wb") as output:
    output.write(b"metadata")
os.setxattr(xattr_path, "user.andock", b"visible")
assert os.getxattr(xattr_path, "user.andock") == b"visible"
assert "user.andock" in os.listxattr(xattr_path)
try:
    os.setxattr(xattr_path, "security.andock", b"hidden")
except OSError as failure:
    assert failure.errno in (errno.EACCES, errno.EPERM), failure
else:
    raise AssertionError("privileged xattr namespace unexpectedly writable")
os.removexattr(xattr_path, "user.andock")
assert "user.andock" not in os.listxattr(xattr_path)

os.chmod(xattr_path, 0o640)
os.chown(xattr_path, 123, 456)
metadata = os.stat(xattr_path)
assert metadata.st_uid == 0 and metadata.st_gid == 0
assert metadata.st_mode & 0o7777 == 0o640

first = os.open("/root/flock", os.O_CREAT | os.O_RDWR, 0o644)
second = os.open("/root/flock", os.O_RDWR)
fcntl.flock(first, fcntl.LOCK_EX | fcntl.LOCK_NB)
try:
    fcntl.flock(second, fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError:
    pass
else:
    raise AssertionError("independent flock did not conflict")
fcntl.flock(first, fcntl.LOCK_UN)
os.close(second)
os.close(first)


def append(label):
    descriptor = os.open(
        "/root/append",
        os.O_CREAT | os.O_WRONLY | os.O_APPEND,
        0o644,
    )
    for index in range(100):
        os.write(descriptor, f"{label}:{index}\n".encode())
    os.close(descriptor)


context = multiprocessing.get_context("fork")
workers = [
    context.Process(target=append, args=(label,))
    for label in ("a", "b")
]
for worker in workers:
    worker.start()
for worker in workers:
    worker.join()
    assert worker.exitcode == 0
lines = open("/root/append").read().splitlines()
assert len(lines) == len(set(lines)) == 200
