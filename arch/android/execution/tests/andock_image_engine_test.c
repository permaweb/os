#define _GNU_SOURCE
#define _FILE_OFFSET_BITS 64

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
	if (result->inode != 0) {
		int status = andock_image_engine_release(result->inode);
		if (status < 0)
			fail("release", status);
	}
	andock_image_result_release(result);
}

static void track(struct andock_image_result *result)
{
	int status = andock_image_engine_retain(result->inode);
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

	struct andock_image_result directory = call(
		ANDOCK_IMAGE_MKDIR, 0, 0755, "/work", NULL);
	andock_image_result_release(&directory);
	struct andock_image_result first = open_file(
		"/work/alpha", O_CREAT | O_RDWR | O_TRUNC | O_CLOEXEC, 0755);
	track(&first);
	write_at(first.guest_fd, 0, "abcdef");
	if (andock_image_engine_mark_dirty(first.inode) < 0 ||
		andock_image_engine_sync(first.inode) < 0)
		fail("initial-sync", -EIO);

	struct andock_image_result link = call(
		ANDOCK_IMAGE_LINK, 0, 0, "/work/alpha", "/work/alpha.link");
	andock_image_result_release(&link);
	struct andock_image_result second = open_file(
		"/work/alpha.link", O_RDWR | O_CLOEXEC, 0);
	track(&second);
	if (first.inode != second.inode ||
		andock_image_engine_materializations() != 1) {
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
	if (andock_image_engine_mark_dirty(first.inode) < 0 ||
		andock_image_engine_sync(first.inode) < 0)
		fail("mmap-sync", -EIO);
	munmap(mapping, 6);
	mapping = mmap(NULL, 6, PROT_READ | PROT_EXEC,
		MAP_PRIVATE, second.guest_fd, 0);
	if (mapping == MAP_FAILED)
		fail("mmap-exec", -errno);
	munmap(mapping, 6);

	struct andock_image_result removed = call(
		ANDOCK_IMAGE_UNLINK, 0, 0, "/work/alpha", NULL);
	andock_image_result_release(&removed);
	write_at(first.guest_fd, 3, "X");
	if (andock_image_engine_mark_dirty(first.inode) < 0 ||
		andock_image_engine_sync(first.inode) < 0)
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
	if (andock_image_engine_mark_dirty(second.inode) < 0 ||
		andock_image_engine_sync(second.inode) < 0)
		fail("rename-sync", -EIO);
	close_tracked(&second);
	close_tracked(&first);
	if (andock_image_engine_stop() < 0)
		fail("stop", -EIO);

	image_fd = open(argv[1], O_RDWR | O_CLOEXEC);
	if (image_fd < 0 || andock_image_engine_start(image_fd) < 0)
		fail("restart", -errno);
	close(image_fd);
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
	andock_image_engine_mark_dirty(target.inode);
	close_tracked(&target);
	struct andock_image_result source = open_file(
		"/work/source", O_CREAT | O_RDWR | O_TRUNC | O_CLOEXEC, 0644);
	track(&source);
	write_at(source.guest_fd, 0, "new");
	andock_image_engine_mark_dirty(source.inode);
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
	andock_image_engine_mark_dirty(persisted.inode);
	if (andock_image_engine_sync(persisted.inode) < 0)
		fail("unlinked-sync", -EIO);
	close_tracked(&persisted);
	expect_status("unlinked-missing",
		raw_call(ANDOCK_IMAGE_RESOLVE, ANDOCK_IMAGE_DEREFERENCE_FINAL,
			"/work/moved", NULL), -ENOENT);

	if (andock_image_engine_stop() < 0)
		fail("final-stop", -EIO);
	puts("ANDOCK_IMAGE_ENGINE_TEST_OK");
	return 0;
}
