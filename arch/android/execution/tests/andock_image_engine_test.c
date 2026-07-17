#define _GNU_SOURCE
#define _FILE_OFFSET_BITS 64

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#include <ext4.h>

#include "extension/andock_image/andock_image_engine.h"

static void fail(const char *step, int status)
{
	fprintf(stderr, "%s failed: %d (%s)\n", step, status,
		status < 0 ? strerror(-status) : strerror(status));
	exit(1);
}

static void expect_status(const char *step, int actual, int expected)
{
	if (actual != expected) {
		fprintf(stderr, "%s: expected %d, got %d\n", step, expected, actual);
		exit(1);
	}
}

static struct andock_image_result call(int operation, int flags, mode_t mode,
		const char *path, const char *second_path)
{
	struct andock_image_result result;
	int status = andock_image_engine_call(operation, flags, mode,
		path, second_path, NULL, 0, &result);
	if (status < 0)
		fail(path, status);
	return result;
}

static struct andock_image_result open_file(
		const char *path, int flags, mode_t mode)
{
	return call(ANDOCK_IMAGE_OPEN, flags, mode, path, NULL);
}

static void close_tracked(struct andock_image_result *result)
{
	if (result->cache_id != 0) {
		int status = andock_image_engine_release(result->cache_id);
		if (status < 0)
			fail("release", status);
	}
	andock_image_result_release(result);
}

static void track(struct andock_image_result *result)
{
	int status = andock_image_engine_retain(result->cache_id);
	if (status < 0)
		fail("retain", status);
}

static void write_at(int fd, off_t offset, const char *data)
{
	size_t size = strlen(data);
	if (pwrite(fd, data, size, offset) != (ssize_t)size)
		fail("pwrite", -errno);
}

static void expect_bytes(int fd, off_t offset, const char *expected)
{
	size_t size = strlen(expected);
	char *actual = calloc(size + 1, 1);
	if (actual == NULL)
		fail("calloc", -ENOMEM);
	if (pread(fd, actual, size, offset) != (ssize_t)size ||
		memcmp(actual, expected, size) != 0) {
		fprintf(stderr, "content mismatch: expected %s, got %s\n",
			expected, actual);
		free(actual);
		exit(1);
	}
	free(actual);
}

static void expect_size(int fd, off_t expected)
{
	struct stat status;
	if (fstat(fd, &status) != 0)
		fail("fstat", -errno);
	if (status.st_size != expected) {
		fprintf(stderr, "size mismatch: expected %lld, got %lld\n",
			(long long) expected, (long long) status.st_size);
		exit(1);
	}
}

static void expect_metadata_times(const char *path)
{
	struct andock_image_result metadata = call(
		ANDOCK_IMAGE_RESOLVE, ANDOCK_IMAGE_DEREFERENCE_FINAL, 0,
		path, NULL);
	if (metadata.mtime == 0 || metadata.atime == 0) {
		fprintf(stderr, "missing virtual timestamps: %lld/%lld\n",
			(long long)metadata.atime, (long long)metadata.mtime);
		exit(1);
	}
	andock_image_result_release(&metadata);
}

static void expect_metadata_mtime(const char *path, time_t expected)
{
	struct andock_image_result metadata = call(
		ANDOCK_IMAGE_RESOLVE, ANDOCK_IMAGE_DEREFERENCE_FINAL, 0,
		path, NULL);
	if (metadata.mtime != expected) {
		fprintf(stderr, "persisted mtime mismatch: expected %lld, got %lld\n",
			(long long)expected, (long long)metadata.mtime);
		exit(1);
	}
	andock_image_result_release(&metadata);
}

static void expect_fill(int fd, off_t offset, size_t size, unsigned char byte)
{
	unsigned char buffer[4096];
	while (size > 0) {
		size_t wanted = size > sizeof(buffer) ? sizeof(buffer) : size;
		if (pread(fd, buffer, wanted, offset) != (ssize_t)wanted)
			fail("pread-fill", -errno);
		for (size_t index = 0; index < wanted; index++) {
			if (buffer[index] != byte) {
				fprintf(stderr,
					"fill mismatch at %lld: expected %02x, got %02x\n",
					(long long)(offset + (off_t)index), byte,
					buffer[index]);
				exit(1);
			}
		}
		offset += (off_t)wanted;
		size -= wanted;
	}
}

static int open_fd_count(void)
{
	DIR *directory = opendir("/proc/self/fd");
	if (directory == NULL)
		fail("opendir-fds", -errno);
	int count = 0;
	while (readdir(directory) != NULL)
		count++;
	closedir(directory);
	return count;
}

static void verify_sparse_fixtures(void)
{
	struct andock_image_result full = open_file(
		"/sparse-full", O_RDONLY | O_CLOEXEC, 0);
	expect_fill(full.guest_fd, 0, 4096, 0x5a);
	expect_fill(full.guest_fd, 4096, 3 * 4096, 0);
	expect_fill(full.guest_fd, 4 * 4096, 4096, 0x5a);
	andock_image_result_release(&full);

	struct andock_image_result tail = open_file(
		"/sparse-tail", O_RDONLY | O_CLOEXEC, 0);
	expect_fill(tail.guest_fd, 0, 4096, 0x54);
	expect_fill(tail.guest_fd, 4096, 123, 0);
	andock_image_result_release(&tail);
}

static int raw_call(int operation, int flags, const char *path,
		const char *second_path)
{
	struct andock_image_result result;
	int status = andock_image_engine_call(operation, flags, 0,
		path, second_path, NULL, 0, &result);
	if (status == 0)
		andock_image_result_release(&result);
	return status;
}

static int raw_data_call(int operation, const char *path,
		const void *data, size_t data_size)
{
	struct andock_image_result result;
	int status = andock_image_engine_call(operation, 0, 0,
		path, NULL, data, data_size, &result);
	if (status == 0)
		andock_image_result_release(&result);
	return status;
}

int main(int argc, char **argv)
{
	if (argc != 2) {
		fprintf(stderr, "usage: %s MEMBER_IMAGE\n", argv[0]);
		return 2;
	}
	int image_fd = open(argv[1], O_RDWR | O_CLOEXEC);
	if (image_fd < 0)
		fail("open-image", -errno);
	int status = andock_image_engine_start(image_fd);
	close(image_fd);
	if (status < 0)
		fail("start", status);
	verify_sparse_fixtures();
	uint64_t materializations = andock_image_engine_materializations();

	struct andock_image_result directory = call(
		ANDOCK_IMAGE_MKDIR, 0, 0755, "/work", NULL);
	andock_image_result_release(&directory);
	struct andock_image_result metadata = call(
		ANDOCK_IMAGE_RESOLVE, ANDOCK_IMAGE_DEREFERENCE_FINAL, 0,
		"/sparse-full", NULL);
	if (metadata.guest_fd >= 0 || metadata.cache_id != 0
	    || andock_image_engine_materializations() != materializations) {
		fprintf(stderr, "metadata resolution materialized file contents\n");
		return 1;
	}
	andock_image_result_release(&metadata);
	expect_metadata_times("/sparse-full");
	directory = call(
		ANDOCK_IMAGE_MKDIR, 0, 0755, "/work/cache-eviction", NULL);
	andock_image_result_release(&directory);
	struct andock_image_result mode_file = open_file(
		"/work/cache-eviction/mode", O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC,
		0600);
	track(&mode_file);
	if ((mode_file.mode & 07777) != 0600) {
		fprintf(stderr, "created file mode mismatch\n");
		return 1;
	}
	int64_t cached_atime;
	int64_t cached_mtime;
	int64_t cached_ctime;
	if (andock_image_engine_timestamps(mode_file.cache_id,
			&cached_atime, &cached_mtime, &cached_ctime) < 0
	    || cached_atime != mode_file.atime
	    || cached_mtime != mode_file.mtime
	    || cached_ctime != mode_file.ctime) {
		fprintf(stderr, "cached file timestamps mismatch\n");
		return 1;
	}
	struct andock_image_result changed_mode = call(
		ANDOCK_IMAGE_CHMOD, 0, 0644, "/work/cache-eviction/mode", NULL);
	if ((changed_mode.mode & 07777) != 0644) {
		fprintf(stderr, "changed file mode mismatch\n");
		return 1;
	}
	andock_image_result_release(&changed_mode);
	expect_status("non-executable-resolution",
		raw_call(ANDOCK_IMAGE_RESOLVE,
			ANDOCK_IMAGE_DEREFERENCE_FINAL | ANDOCK_IMAGE_EXECUTABLE,
			"/work/cache-eviction/mode", NULL), -EACCES);
	close_tracked(&mode_file);
	struct andock_image_result executable = open_file(
		"/work/cache-eviction/executable",
		O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC, 0755);
	track(&executable);
	close_tracked(&executable);
	struct andock_image_result executable_resolution = call(
		ANDOCK_IMAGE_RESOLVE,
		ANDOCK_IMAGE_DEREFERENCE_FINAL | ANDOCK_IMAGE_EXECUTABLE,
		0, "/work/cache-eviction/executable", NULL);
	if ((executable_resolution.mode & 07777) != 0755
	    || executable_resolution.guest_fd < 0) {
		fprintf(stderr, "executable resolution metadata mismatch\n");
		return 1;
	}
	andock_image_result_release(&executable_resolution);
	int baseline_fds = open_fd_count();
	for (int index = 0; index < 512; index++) {
		char path[64];
		snprintf(path, sizeof(path), "/work/cache-eviction/%03d", index);
		struct andock_image_result transient = open_file(
			path, O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC, 0644);
		track(&transient);
		write_at(transient.guest_fd, 0, "transient");
		if (andock_image_engine_mark_dirty(transient.cache_id) < 0)
			fail("cache-eviction-dirty", -EIO);
		close_tracked(&transient);
	}
	if (open_fd_count() != baseline_fds) {
		fprintf(stderr, "closed inode cache retained file descriptors\n");
		return 1;
	}
	directory = call(
		ANDOCK_IMAGE_MKDIR, 0, 0755, "/work/non-empty", NULL);
	andock_image_result_release(&directory);
	struct andock_image_result child = open_file(
		"/work/non-empty/child", O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC,
		0644);
	track(&child);
	write_at(child.guest_fd, 0, "preserved-child");
	andock_image_engine_mark_dirty(child.cache_id);
	if (andock_image_engine_sync(child.cache_id) < 0)
		fail("non-empty-child-sync", -EIO);
	expect_status("non-empty-rmdir",
		raw_call(ANDOCK_IMAGE_UNLINK, AT_REMOVEDIR,
			"/work/non-empty", NULL), -ENOTEMPTY);
	expect_bytes(child.guest_fd, 0, "preserved-child");
	struct andock_image_result child_reopened = open_file(
		"/work/non-empty/child", O_RDONLY | O_CLOEXEC, 0);
	expect_bytes(child_reopened.guest_fd, 0, "preserved-child");
	andock_image_result_release(&child_reopened);
	struct andock_image_result removed = call(
		ANDOCK_IMAGE_UNLINK, 0, 0, "/work/non-empty/child", NULL);
	andock_image_result_release(&removed);
	expect_bytes(child.guest_fd, 0, "preserved-child");
	removed = call(ANDOCK_IMAGE_UNLINK, AT_REMOVEDIR, 0,
		"/work/non-empty", NULL);
	andock_image_result_release(&removed);
	close_tracked(&child);
	struct andock_image_result socket_node = call(
		ANDOCK_IMAGE_SOCKET_CREATE, 0, 0755, "/work/socket", NULL);
	if (socket_node.type != ANDOCK_IMAGE_SOCKET
	    || !S_ISSOCK(socket_node.mode)
	    || (socket_node.mode & 0777) != 0755) {
		fprintf(stderr, "socket node metadata mismatch\n");
		return 1;
	}
	uint64_t socket_inode = socket_node.inode;
	uint64_t socket_token = socket_node.token;
	andock_image_result_release(&socket_node);
	expect_status("socket-exists",
		raw_call(ANDOCK_IMAGE_SOCKET_CREATE, 0, "/work/socket", NULL),
		-EEXIST);
	uint64_t wrong_socket_token = socket_token + 1;
	expect_status("socket-cancel-wrong-generation",
		raw_data_call(ANDOCK_IMAGE_SOCKET_CANCEL, "/work/socket",
			&wrong_socket_token, sizeof(wrong_socket_token)), 0);
	struct andock_image_result socket_still_present = call(
		ANDOCK_IMAGE_RESOLVE, ANDOCK_IMAGE_DEREFERENCE_FINAL, 0,
		"/work/socket", NULL);
	if (socket_still_present.type != ANDOCK_IMAGE_SOCKET
	    || socket_still_present.inode != socket_inode) {
		fprintf(stderr, "socket cancellation removed the wrong generation\n");
		return 1;
	}
	andock_image_result_release(&socket_still_present);
	expect_status("socket-cancel-generation",
		raw_data_call(ANDOCK_IMAGE_SOCKET_CANCEL, "/work/socket",
			&socket_token, sizeof(socket_token)), 0);
	expect_status("socket-cancelled",
		raw_call(ANDOCK_IMAGE_RESOLVE, ANDOCK_IMAGE_DEREFERENCE_FINAL,
			"/work/socket", NULL), -ENOENT);
	socket_node = call(
		ANDOCK_IMAGE_SOCKET_CREATE, 0, 0700, "/work/socket", NULL);
	if (!S_ISSOCK(socket_node.mode) || (socket_node.mode & 0777) != 0700) {
		fprintf(stderr, "socket retry metadata mismatch\n");
		return 1;
	}
	socket_inode = socket_node.inode;
	andock_image_result_release(&socket_node);
	struct andock_image_result socket_link = call(
		ANDOCK_IMAGE_LINK, 0, 0, "/work/socket", "/work/socket.link");
	if (socket_link.type != ANDOCK_IMAGE_SOCKET
	    || socket_link.inode != socket_inode) {
		fprintf(stderr, "socket hard link metadata mismatch\n");
		return 1;
	}
	andock_image_result_release(&socket_link);
	removed = call(ANDOCK_IMAGE_UNLINK, 0, 0, "/work/socket", NULL);
	andock_image_result_release(&removed);
	expect_status("socket-unlinked",
		raw_call(ANDOCK_IMAGE_RESOLVE, ANDOCK_IMAGE_DEREFERENCE_FINAL,
			"/work/socket", NULL), -ENOENT);
	struct andock_image_result socket_alias = call(
		ANDOCK_IMAGE_RESOLVE, ANDOCK_IMAGE_DEREFERENCE_FINAL, 0,
		"/work/socket.link", NULL);
	if (socket_alias.type != ANDOCK_IMAGE_SOCKET
	    || socket_alias.inode != socket_inode) {
		fprintf(stderr, "socket hard link did not survive source unlink\n");
		return 1;
	}
	andock_image_result_release(&socket_alias);
	removed = call(ANDOCK_IMAGE_UNLINK, 0, 0, "/work/socket.link", NULL);
	andock_image_result_release(&removed);
	struct andock_image_result old_socket_generation = call(
		ANDOCK_IMAGE_SOCKET_CREATE, 0, 0755,
		"/work/socket-generation", NULL);
	uint64_t old_generation_inode = old_socket_generation.inode;
	uint64_t old_generation_token = old_socket_generation.token;
	andock_image_result_release(&old_socket_generation);
	removed = call(
		ANDOCK_IMAGE_UNLINK, 0, 0, "/work/socket-generation", NULL);
	andock_image_result_release(&removed);
	struct andock_image_result new_socket_generation = call(
		ANDOCK_IMAGE_SOCKET_CREATE, 0, 0755,
		"/work/socket-generation", NULL);
	if (new_socket_generation.inode != old_generation_inode) {
		fprintf(stderr, "socket generation test did not force inode reuse\n");
		return 1;
	}
	uint64_t new_generation_token = new_socket_generation.token;
	andock_image_result_release(&new_socket_generation);
	expect_status("socket-cancel-stale-reused-inode",
		raw_data_call(ANDOCK_IMAGE_SOCKET_CANCEL,
			"/work/socket-generation", &old_generation_token,
			sizeof(old_generation_token)), 0);
	struct andock_image_result generation_still_present = call(
		ANDOCK_IMAGE_RESOLVE, ANDOCK_IMAGE_DEREFERENCE_FINAL, 0,
		"/work/socket-generation", NULL);
	if (generation_still_present.type != ANDOCK_IMAGE_SOCKET
	    || generation_still_present.token != 0) {
		fprintf(stderr, "stale cancellation removed reused socket inode\n");
		return 1;
	}
	andock_image_result_release(&generation_still_present);
	expect_status("socket-cancel-current-reused-inode",
		raw_data_call(ANDOCK_IMAGE_SOCKET_CANCEL,
			"/work/socket-generation", &new_generation_token,
			sizeof(new_generation_token)), 0);
	expect_status("socket-current-generation-cancelled",
		raw_call(ANDOCK_IMAGE_RESOLVE, ANDOCK_IMAGE_DEREFERENCE_FINAL,
			"/work/socket-generation", NULL), -ENOENT);
	struct andock_image_result rename_source_socket = call(
		ANDOCK_IMAGE_SOCKET_CREATE, 0, 0755,
		"/work/rename-source.socket", NULL);
	uint64_t rename_source_inode = rename_source_socket.inode;
	uint64_t rename_source_token = rename_source_socket.token;
	andock_image_result_release(&rename_source_socket);
	struct andock_image_result rename_target_socket = call(
		ANDOCK_IMAGE_SOCKET_CREATE, 0, 0700,
		"/work/rename-target.socket", NULL);
	uint64_t rename_target_inode = rename_target_socket.inode;
	uint64_t rename_target_token = rename_target_socket.token;
	andock_image_result_release(&rename_target_socket);
	if (rename_source_inode == rename_target_inode) {
		fprintf(stderr, "socket rename fixtures unexpectedly share an inode\n");
		return 1;
	}
	struct andock_image_result renamed_socket = call(
		ANDOCK_IMAGE_RENAME, 0, 0,
		"/work/rename-source.socket", "/work/rename-target.socket");
	andock_image_result_release(&renamed_socket);
	expect_status("socket-rename-source-removed",
		raw_call(ANDOCK_IMAGE_RESOLVE, ANDOCK_IMAGE_DEREFERENCE_FINAL,
			"/work/rename-source.socket", NULL), -ENOENT);
	struct andock_image_result renamed_socket_target = call(
		ANDOCK_IMAGE_RESOLVE, ANDOCK_IMAGE_DEREFERENCE_FINAL, 0,
		"/work/rename-target.socket", NULL);
	if (renamed_socket_target.type != ANDOCK_IMAGE_SOCKET
	    || renamed_socket_target.inode != rename_source_inode) {
		fprintf(stderr, "socket rename-over-existing kept the wrong node\n");
		return 1;
	}
	andock_image_result_release(&renamed_socket_target);
	expect_status("socket-renamed-target-stale-cancel",
		raw_data_call(ANDOCK_IMAGE_SOCKET_CANCEL,
			"/work/rename-target.socket", &rename_target_token,
			sizeof(rename_target_token)), 0);
	renamed_socket_target = call(
		ANDOCK_IMAGE_RESOLVE, ANDOCK_IMAGE_DEREFERENCE_FINAL, 0,
		"/work/rename-target.socket", NULL);
	if (renamed_socket_target.inode != rename_source_inode) {
		fprintf(stderr, "replaced socket reservation deleted source node\n");
		return 1;
	}
	andock_image_result_release(&renamed_socket_target);
	expect_status("socket-renamed-source-cancel",
		raw_data_call(ANDOCK_IMAGE_SOCKET_CANCEL,
			"/work/rename-target.socket", &rename_source_token,
			sizeof(rename_source_token)), 0);
	expect_status("socket-renamed-source-cancelled",
		raw_call(ANDOCK_IMAGE_RESOLVE, ANDOCK_IMAGE_DEREFERENCE_FINAL,
			"/work/rename-target.socket", NULL), -ENOENT);
	materializations = andock_image_engine_materializations();
	struct andock_image_result first = open_file(
		"/work/alpha", O_CREAT | O_RDWR | O_TRUNC | O_CLOEXEC, 0755);
	track(&first);
	write_at(first.guest_fd, 0, "abcdef");
	if (andock_image_engine_mark_dirty(first.cache_id) < 0 ||
		andock_image_engine_sync(first.cache_id) < 0)
		fail("initial-sync", -EIO);

	struct andock_image_result link = call(
		ANDOCK_IMAGE_LINK, 0, 0, "/work/alpha", "/work/alpha.link");
	andock_image_result_release(&link);
	struct andock_image_result second = open_file(
		"/work/alpha.link", O_RDWR | O_CLOEXEC, 0);
	track(&second);
	if (first.inode != second.inode ||
		andock_image_engine_materializations() != materializations + 1) {
		fprintf(stderr, "inode cache did not reuse one materialization\n");
		return 1;
	}
	write_at(first.guest_fd, 1, "Z");
	expect_bytes(second.guest_fd, 0, "aZcdef");

	char *mapping = mmap(NULL, 6, PROT_READ | PROT_WRITE,
		MAP_SHARED, second.guest_fd, 0);
	if (mapping == MAP_FAILED)
		fail("mmap-shared", -errno);
	mapping[2] = 'Y';
	if (msync(mapping, 6, MS_SYNC) != 0)
		fail("msync", -errno);
	if (andock_image_engine_mark_dirty(first.cache_id) < 0 ||
		andock_image_engine_sync(first.cache_id) < 0)
		fail("mmap-sync", -EIO);
	munmap(mapping, 6);
	mapping = mmap(NULL, 6, PROT_READ | PROT_EXEC,
		MAP_PRIVATE, second.guest_fd, 0);
	if (mapping == MAP_FAILED)
		fail("mmap-exec", -errno);
	munmap(mapping, 6);

	removed = call(
		ANDOCK_IMAGE_UNLINK, 0, 0, "/work/alpha", NULL);
	andock_image_result_release(&removed);
	write_at(first.guest_fd, 3, "X");
	if (andock_image_engine_mark_dirty(first.cache_id) < 0 ||
		andock_image_engine_sync(first.cache_id) < 0)
		fail("hardlink-sync", -EIO);
	struct andock_image_result via_link = open_file(
		"/work/alpha.link", O_RDONLY | O_CLOEXEC, 0);
	expect_bytes(via_link.guest_fd, 0, "aZYXef");
	andock_image_result_release(&via_link);

	struct andock_image_result renamed = call(
		ANDOCK_IMAGE_RENAME, 0, 0,
		"/work/alpha.link", "/work/moved");
	andock_image_result_release(&renamed);
	write_at(second.guest_fd, 4, "W");
	if (andock_image_engine_mark_dirty(second.cache_id) < 0 ||
		andock_image_engine_sync(second.cache_id) < 0)
		fail("rename-sync", -EIO);
	struct stat moved_status;
	if (fstat(second.guest_fd, &moved_status) != 0)
		fail("moved-fstat", -errno);
	time_t moved_mtime = moved_status.st_mtime;
	close_tracked(&second);
	close_tracked(&first);

	struct andock_image_result mapped = open_file(
		"/work/mapped-after-close",
		O_CREAT | O_RDWR | O_TRUNC | O_CLOEXEC, 0755);
	track(&mapped);
	if (ftruncate(mapped.guest_fd, 4096) != 0)
		fail("mapped-truncate", -errno);
	write_at(mapped.guest_fd, 0, "before42");
	if (andock_image_engine_mark_dirty(mapped.cache_id) < 0
	    || andock_image_engine_sync(mapped.cache_id) < 0)
		fail("mapped-initial-sync", -EIO);
	mapping = mmap(NULL, 4096, PROT_READ | PROT_WRITE,
		MAP_SHARED, mapped.guest_fd, 0);
	if (mapping == MAP_FAILED)
		fail("mapped-after-close-mmap", -errno);
	uint64_t mapped_cache_id = mapped.cache_id;
	if (andock_image_engine_mark_mapped(mapped_cache_id) < 0)
		fail("mapped-after-close-track", -EIO);
	close_tracked(&mapped);
	memcpy(mapping, "MAPPED42", 8);
	if (msync(mapping, 4096, MS_SYNC) != 0)
		fail("mapped-after-close-msync", -errno);
	if (andock_image_engine_sync_all() < 0)
		fail("mapped-after-close-sync", -EIO);
	struct andock_image_result mapped_executable = call(
		ANDOCK_IMAGE_RESOLVE,
		ANDOCK_IMAGE_DEREFERENCE_FINAL | ANDOCK_IMAGE_EXECUTABLE,
		0, "/work/mapped-after-close", NULL);
	andock_image_result_release(&mapped_executable);
	memcpy(mapping, "RETAIN42", 8);
	if (msync(mapping, 4096, MS_SYNC) != 0
	    || andock_image_engine_sync_all() < 0)
		fail("mapped-after-executable-sync", -EIO);
	munmap(mapping, 4096);
	if (andock_image_engine_stop() < 0)
		fail("stop", -EIO);

	image_fd = open(argv[1], O_RDWR | O_CLOEXEC);
	if (image_fd < 0 || andock_image_engine_start(image_fd) < 0)
		fail("restart", -errno);
	close(image_fd);
	verify_sparse_fixtures();
	expect_metadata_times("/sparse-full");
	expect_metadata_mtime("/work/moved", moved_mtime);
	struct andock_image_result mapped_persisted = open_file(
		"/work/mapped-after-close", O_RDONLY | O_CLOEXEC, 0);
	expect_bytes(mapped_persisted.guest_fd, 0, "RETAIN42");
	andock_image_result_release(&mapped_persisted);
	expect_status("old-link-missing",
		raw_call(ANDOCK_IMAGE_RESOLVE, ANDOCK_IMAGE_DEREFERENCE_FINAL,
			"/work/alpha.link", NULL), -ENOENT);
	struct andock_image_result persisted = open_file(
		"/work/moved", O_RDWR | O_CLOEXEC, 0);
	track(&persisted);
	expect_bytes(persisted.guest_fd, 0, "aZYXWf");

	struct andock_image_result target = open_file(
		"/work/target", O_CREAT | O_RDWR | O_TRUNC | O_CLOEXEC, 0644);
	track(&target);
	write_at(target.guest_fd, 0, "old");
	andock_image_engine_mark_dirty(target.cache_id);
	close_tracked(&target);
	struct andock_image_result source = open_file(
		"/work/source", O_CREAT | O_RDWR | O_TRUNC | O_CLOEXEC, 0644);
	track(&source);
	write_at(source.guest_fd, 0, "new");
	andock_image_engine_mark_dirty(source.cache_id);
	close_tracked(&source);
	struct andock_image_result replaced = call(
		ANDOCK_IMAGE_RENAME, 0, 0, "/work/source", "/work/target");
	andock_image_result_release(&replaced);
	struct andock_image_result replacement = open_file(
		"/work/target", O_RDONLY | O_CLOEXEC, 0);
	expect_bytes(replacement.guest_fd, 0, "new");
	andock_image_result_release(&replacement);

	removed = call(ANDOCK_IMAGE_UNLINK, 0, 0, "/work/moved", NULL);
	andock_image_result_release(&removed);
	write_at(persisted.guest_fd, 0, "gone");
	andock_image_engine_mark_dirty(persisted.cache_id);
	if (andock_image_engine_sync(persisted.cache_id) < 0)
		fail("unlinked-sync", -EIO);
	close_tracked(&persisted);
	expect_status("unlinked-missing",
		raw_call(ANDOCK_IMAGE_RESOLVE, ANDOCK_IMAGE_DEREFERENCE_FINAL,
			"/work/moved", NULL), -ENOENT);

	struct andock_image_result old_generation = open_file(
		"/work/reuse-old", O_CREAT | O_RDWR | O_TRUNC | O_CLOEXEC, 0644);
	track(&old_generation);
	write_at(old_generation.guest_fd, 0, "old");
	andock_image_engine_mark_dirty(old_generation.cache_id);
	if (andock_image_engine_sync(old_generation.cache_id) < 0)
		fail("reuse-old-sync", -EIO);
	uint64_t reused_inode = old_generation.inode;
	uint64_t old_cache_id = old_generation.cache_id;
	removed = call(
		ANDOCK_IMAGE_UNLINK, 0, 0, "/work/reuse-old", NULL);
	andock_image_result_release(&removed);
	write_at(old_generation.guest_fd, 0, "still-open-old-generation");
	andock_image_engine_mark_dirty(old_generation.cache_id);
	expect_bytes(old_generation.guest_fd, 0,
		"still-open-old-generation");

	struct andock_image_result new_generation;
	char reused_path[64];
	bool found_reuse = false;
	for (int attempt = 0; attempt < 1024; attempt++) {
		snprintf(reused_path, sizeof(reused_path),
			"/work/reuse-%d", attempt);
		new_generation = open_file(reused_path,
			O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC, 0644);
		track(&new_generation);
		if (new_generation.inode == reused_inode) {
			found_reuse = true;
			break;
		}
		close_tracked(&new_generation);
		removed = call(
			ANDOCK_IMAGE_UNLINK, 0, 0, reused_path, NULL);
		andock_image_result_release(&removed);
	}
	if (!found_reuse || new_generation.cache_id == old_cache_id) {
		fprintf(stderr, "unlinked inode generation was not isolated\n");
		return 1;
	}
	write_at(new_generation.guest_fd, 0, "new");
	andock_image_engine_mark_dirty(new_generation.cache_id);
	if (andock_image_engine_sync(new_generation.cache_id) < 0)
		fail("reuse-new-sync", -EIO);
	expect_size(new_generation.guest_fd, 3);
	expect_bytes(new_generation.guest_fd, 0, "new");
	expect_bytes(old_generation.guest_fd, 0,
		"still-open-old-generation");
	close_tracked(&old_generation);
	expect_size(new_generation.guest_fd, 3);
	expect_bytes(new_generation.guest_fd, 0, "new");
	close_tracked(&new_generation);
	struct andock_image_result reopened_generation = open_file(
		reused_path, O_RDONLY | O_CLOEXEC, 0);
	expect_size(reopened_generation.guest_fd, 3);
	expect_bytes(reopened_generation.guest_fd, 0, "new");
	andock_image_result_release(&reopened_generation);

	struct andock_image_result stale_generation = open_file(
		"/work/no-truncate", O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC, 0644);
	track(&stale_generation);
	write_at(stale_generation.guest_fd, 0, "old-generation-with-long-tail");
	andock_image_engine_mark_dirty(stale_generation.cache_id);
	if (andock_image_engine_sync(stale_generation.cache_id) < 0)
		fail("no-truncate-old-sync", -EIO);
	uint64_t stale_inode = stale_generation.inode;
	uint64_t stale_cache_id = stale_generation.cache_id;
	if (ext4_fremove("/andock/work/no-truncate") != EOK)
		fail("no-truncate-raw-remove", -EIO);
	struct andock_image_result fresh_generation = open_file(
		"/work/no-truncate", O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC, 0644);
	track(&fresh_generation);
	if (fresh_generation.inode != stale_inode
	    || fresh_generation.cache_id == stale_cache_id) {
		fprintf(stderr,
			"created inode generation reused stale materialization\n");
		return 1;
	}
	write_at(fresh_generation.guest_fd, 0, "new");
	andock_image_engine_mark_dirty(fresh_generation.cache_id);
	if (andock_image_engine_sync(fresh_generation.cache_id) < 0)
		fail("no-truncate-new-sync", -EIO);
	expect_size(fresh_generation.guest_fd, 3);
	expect_bytes(fresh_generation.guest_fd, 0, "new");
	expect_bytes(stale_generation.guest_fd, 0,
		"old-generation-with-long-tail");
	close_tracked(&stale_generation);
	close_tracked(&fresh_generation);
	reopened_generation = open_file(
		"/work/no-truncate", O_RDONLY | O_CLOEXEC, 0);
	expect_size(reopened_generation.guest_fd, 3);
	expect_bytes(reopened_generation.guest_fd, 0, "new");
	andock_image_result_release(&reopened_generation);

	if (andock_image_engine_stop() < 0)
		fail("final-stop", -EIO);
	puts("ANDOCK_IMAGE_ENGINE_TEST_OK");
	return 0;
}
