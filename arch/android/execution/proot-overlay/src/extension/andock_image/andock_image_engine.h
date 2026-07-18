#ifndef ANDOCK_IMAGE_ENGINE_H
#define ANDOCK_IMAGE_ENGINE_H

#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

enum {
	ANDOCK_IMAGE_MISSING = 0,
	ANDOCK_IMAGE_FILE = 1,
	ANDOCK_IMAGE_DIRECTORY = 2,
	ANDOCK_IMAGE_SYMLINK = 3,
	ANDOCK_IMAGE_OTHER = 4,
	ANDOCK_IMAGE_SOCKET = 5,
};

enum {
	ANDOCK_IMAGE_RESOLVE = 1,
	ANDOCK_IMAGE_OPEN = 2,
	ANDOCK_IMAGE_READLINK = 3,
	ANDOCK_IMAGE_LIST = 4,
	ANDOCK_IMAGE_MKDIR = 5,
	ANDOCK_IMAGE_UNLINK = 6,
	ANDOCK_IMAGE_RENAME = 7,
	ANDOCK_IMAGE_SYMLINK_CREATE = 8,
	ANDOCK_IMAGE_CHMOD = 9,
	ANDOCK_IMAGE_TRUNCATE = 10,
	ANDOCK_IMAGE_SOCKET_CREATE = 11,
	ANDOCK_IMAGE_STATFS = 12,
	ANDOCK_IMAGE_UTIMENS = 13,
	ANDOCK_IMAGE_LINK = 14,
	ANDOCK_IMAGE_LIST_XATTR = 15,
	ANDOCK_IMAGE_GET_XATTR = 16,
	ANDOCK_IMAGE_SET_XATTR = 17,
	ANDOCK_IMAGE_REMOVE_XATTR = 18,
	ANDOCK_IMAGE_SOCKET_CANCEL = 19,
	ANDOCK_IMAGE_SOCKET_COMMIT = 20,
};

enum {
	ANDOCK_IMAGE_DEREFERENCE_FINAL = 1,
	ANDOCK_IMAGE_ALLOW_MISSING_FINAL = 2,
	ANDOCK_IMAGE_EXECUTABLE = 4,
};

struct andock_image_result {
	int type;
	mode_t mode;
	uint64_t size;
	uint64_t inode;
	uint64_t cache_id;
	uint64_t token;
	int64_t atime;
	int64_t mtime;
	int64_t ctime;
	nlink_t links;
	char *path;
	uint8_t *data;
	size_t data_size;
	int guest_fd;
	int backing_fd;
};

int andock_image_engine_start(int image_fd);
int andock_image_engine_stop(void);
int andock_image_engine_call(int operation, int flags, mode_t mode,
		const char *path, const char *second_path,
		const void *data, size_t data_size,
		struct andock_image_result *result);
int andock_image_engine_flush(void);
int andock_image_engine_retain(uint64_t cache_id);
int andock_image_engine_release(uint64_t cache_id);
int andock_image_engine_mark_dirty(uint64_t cache_id);
int andock_image_engine_mark_dirty_range(uint64_t cache_id,
		uint64_t offset, uint64_t length);
int andock_image_engine_mark_mapped(uint64_t cache_id);
int andock_image_engine_timestamps(uint64_t cache_id,
	int64_t *atime, int64_t *mtime, int64_t *ctime);
int andock_image_engine_writeback(uint64_t cache_id);
int andock_image_engine_sync(uint64_t cache_id);
int andock_image_engine_sync_all(void);
uint64_t andock_image_engine_materializations(void);
void andock_image_result_release(struct andock_image_result *result);

#endif
