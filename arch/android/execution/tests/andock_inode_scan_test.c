#define _GNU_SOURCE
#define _FILE_OFFSET_BITS 64

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "extension/andock_image/andock_image_engine.h"

static void expect(const char *step, int actual, int expected)
{
	if (actual != expected) {
		fprintf(stderr, "%s: expected %d, got %d\n", step, expected, actual);
		exit(1);
	}
}

int main(int argc, char **argv)
{
	if (argc != 3)
		return 2;
	unsigned long minimum_inode = strtoul(argv[2], NULL, 10);
	int fd = open(argv[1], O_RDWR | O_CLOEXEC);
	if (fd < 0)
		return 2;
	expect("start", andock_image_engine_start(fd), 0);
	close(fd);

	struct andock_image_result result;
	int status = andock_image_engine_call(ANDOCK_IMAGE_OPEN,
		O_CREAT | O_EXCL | O_RDWR, 0644, "/probe", NULL, NULL, 0, &result);
	if (minimum_inode == 0)
		expect("file exhausted", status, -ENOSPC);
	else {
		expect("create", status, 0);
		if (result.inode < minimum_inode) {
			fprintf(stderr, "allocated inode %llu in full group\n",
				(unsigned long long)result.inode);
			return 1;
		}
		expect("write", pwrite(result.backing_fd, "probe\n", 6, 0), 6);
		expect("dirty", andock_image_engine_mark_dirty(result.cache_id), 0);
		expect("sync", andock_image_engine_sync(result.cache_id), 0);
		andock_image_result_release(&result);
	}
	status = andock_image_engine_call(ANDOCK_IMAGE_MKDIR, 0, 0755,
		"/directory", NULL, NULL, 0, &result);
	expect("directory", status, minimum_inode == 0 ? -ENOSPC : 0);
	if (status == 0)
		andock_image_result_release(&result);
	expect("stop", andock_image_engine_stop(), 0);

	if (minimum_inode != 0) {
		fd = open(argv[1], O_RDWR | O_CLOEXEC);
		if (fd < 0)
			return 2;
		expect("restart", andock_image_engine_start(fd), 0);
		close(fd);
		expect("read open", andock_image_engine_call(ANDOCK_IMAGE_OPEN,
			O_RDONLY, 0, "/probe", NULL, NULL, 0, &result), 0);
		char data[6];
		expect("read", pread(result.backing_fd, data, sizeof(data), 0), 6);
		if (memcmp(data, "probe\n", sizeof(data)) != 0)
			return 1;
		andock_image_result_release(&result);
		expect("read stop", andock_image_engine_stop(), 0);
	}
	puts("ANDOCK_INODE_SCAN_TEST_OK");
	return 0;
}
