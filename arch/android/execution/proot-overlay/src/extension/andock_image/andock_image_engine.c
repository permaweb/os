#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#ifndef _FILE_OFFSET_BITS
#define _FILE_OFFSET_BITS 64
#endif

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#include <ext4.h>
#include <ext4_blockdev.h>
#include <ext4_errno.h>
#include <ext4_fs.h>
#include <ext4_extent.h>
#include <ext4_inode.h>
#include <ext4_super.h>
#include <ext4_types.h>

#include "extension/andock_image/andock_image_engine.h"

#define ANDOCK_IMAGE_BLOCK_SIZE 512U
#define ANDOCK_IMAGE_DEVICE "andock-member-image"
#define ANDOCK_IMAGE_MOUNT "/andock/"
#define ANDOCK_IMAGE_MAX_SYMLINKS 40
#define ANDOCK_IMAGE_IO_BYTES (1024U * 1024U)
#define ANDOCK_IMAGE_MAX_XATTR_BYTES (1024U * 1024U)
#define ANDOCK_IMAGE_DIRECTORY_CACHE_SIZE 256U
#define ANDOCK_IMAGE_SPARSE_BLOCK_BYTES 4096U
#define ANDOCK_IMAGE_HOST_FREE_RESERVE_BYTES (UINT64_C(512) * 1024 * 1024)

#ifndef MFD_EXEC
#define MFD_EXEC 0x0010U
#endif

#ifndef AT_REMOVEDIR
#define AT_REMOVEDIR 0x200
#endif

#ifndef AT_SYMLINK_NOFOLLOW
#define AT_SYMLINK_NOFOLLOW 0x100
#endif

#ifndef XATTR_CREATE
#define XATTR_CREATE 1
#endif

#ifndef XATTR_REPLACE
#define XATTR_REPLACE 2
#endif

static int member_image_fd = -1;

struct dirty_range {
	uint64_t start;
	uint64_t end;
	struct dirty_range *next;
};

struct cached_inode {
	uint64_t inode;
	uint64_t cache_id;
	int memory_fd;
	unsigned int references;
	uint64_t persisted_size;
	unsigned int mappings;
	unsigned int writable_mappings;
	int64_t atime;
	int64_t mtime;
	int64_t ctime;
	bool dirty;
	bool full_dirty;
	bool timestamps_explicit;
	bool unlinked;
	struct dirty_range *dirty_ranges;
	struct cached_inode *next;
};

struct socket_reservation {
	uint64_t token;
	uint64_t inode;
	char *path;
	struct socket_reservation *next;
};

static struct cached_inode *inode_cache;
static struct socket_reservation *socket_reservations;
static uint64_t materialization_count;
static uint64_t next_cache_id;
static uint64_t next_socket_token;

struct raw_lookup {
	char path[PATH_MAX];
	struct ext4_inode inode;
	uint32_t inode_number;
	uint32_t mode;
	bool valid;
};

static struct raw_lookup latest_lookup;
static bool reuse_latest_lookup;

struct cached_directory {
	char path[PATH_MAX];
	uint64_t generation;
};

static struct cached_directory directory_cache[ANDOCK_IMAGE_DIRECTORY_CACHE_SIZE];
static unsigned int next_directory_cache;
static uint64_t directory_cache_generation = 1;

static void clear_directory_cache(void)
{
	if (directory_cache_generation == UINT64_MAX) {
		memset(directory_cache, 0, sizeof(directory_cache));
		directory_cache_generation = 1;
	} else
		directory_cache_generation++;
	next_directory_cache = 0;
}

static bool cached_directory(const char *path)
{
	unsigned int index;
	for (index = 0; index < ANDOCK_IMAGE_DIRECTORY_CACHE_SIZE; index++) {
		if (directory_cache[index].generation == directory_cache_generation
		    && strcmp(directory_cache[index].path, path) == 0)
			return true;
	}
	return false;
}

static void cache_directory(const char *path)
{
	struct cached_directory *entry =
		&directory_cache[next_directory_cache];
	strcpy(entry->path, path);
	entry->generation = directory_cache_generation;
	next_directory_cache = (next_directory_cache + 1)
		% ANDOCK_IMAGE_DIRECTORY_CACHE_SIZE;
}

static bool path_at_or_below(const char *path, const char *parent)
{
	size_t parent_length = strlen(parent);
	return strcmp(path, parent) == 0
		|| (strncmp(path, parent, parent_length) == 0
		    && path[parent_length] == '/');
}

static void remove_socket_reservation(struct socket_reservation *reservation)
{
	struct socket_reservation **cursor = &socket_reservations;
	while (*cursor != NULL) {
		if (*cursor == reservation) {
			*cursor = reservation->next;
			free(reservation->path);
			free(reservation);
			return;
		}
		cursor = &(*cursor)->next;
	}
}

static void invalidate_socket_reservations(const char *path)
{
	struct socket_reservation **cursor = &socket_reservations;
	while (*cursor != NULL) {
		struct socket_reservation *reservation = *cursor;
		if (strcmp(reservation->path, path) != 0) {
			cursor = &reservation->next;
			continue;
		}
		*cursor = reservation->next;
		free(reservation->path);
		free(reservation);
	}
}

static void invalidate_socket_reservations_below(const char *path)
{
	struct socket_reservation **cursor = &socket_reservations;
	while (*cursor != NULL) {
		struct socket_reservation *reservation = *cursor;
		if (!path_at_or_below(reservation->path, path)) {
			cursor = &reservation->next;
			continue;
		}
		*cursor = reservation->next;
		free(reservation->path);
		free(reservation);
	}
}

static struct socket_reservation *find_socket_reservation(uint64_t token)
{
	struct socket_reservation *reservation = socket_reservations;
	while (reservation != NULL) {
		if (reservation->token == token)
			return reservation;
		reservation = reservation->next;
	}
	return NULL;
}

static void rename_socket_reservations(const char *source, const char *target)
{
	struct socket_reservation **cursor;
	size_t source_length = strlen(source);
	if (strcmp(source, target) == 0)
		return;
	invalidate_socket_reservations_below(target);
	cursor = &socket_reservations;
	while (*cursor != NULL) {
		struct socket_reservation *reservation = *cursor;
		if (!path_at_or_below(reservation->path, source)) {
			cursor = &reservation->next;
			continue;
		}
		const char *suffix = reservation->path + source_length;
		size_t length = strlen(target) + strlen(suffix) + 1;
		char *renamed = malloc(length);
		if (renamed == NULL) {
			*cursor = reservation->next;
			free(reservation->path);
			free(reservation);
			continue;
		}
		strcpy(renamed, target);
		strcat(renamed, suffix);
		free(reservation->path);
		reservation->path = renamed;
		cursor = &reservation->next;
	}
}

static void clear_socket_reservations(void)
{
	while (socket_reservations != NULL)
		remove_socket_reservation(socket_reservations);
}

static int create_memory_file(const char *name, unsigned int flags)
{
#ifdef __NR_memfd_create
	return (int)syscall(__NR_memfd_create, name, flags);
#else
	(void)name;
	(void)flags;
	errno = ENOSYS;
	return -1;
#endif
}

static int image_open(struct ext4_blockdev *device);
static int image_read(struct ext4_blockdev *device, void *buffer,
		uint64_t block, uint32_t count);
static int image_write(struct ext4_blockdev *device, const void *buffer,
		uint64_t block, uint32_t count);
static int image_close(struct ext4_blockdev *device);

EXT4_BLOCKDEV_STATIC_INSTANCE(
	member_image,
	ANDOCK_IMAGE_BLOCK_SIZE,
	0,
	image_open,
	image_read,
	image_write,
	image_close,
	NULL,
	NULL
);

static uint64_t host_to_be64(uint64_t value)
{
	uint32_t high = htonl((uint32_t)(value >> 32));
	uint32_t low = htonl((uint32_t)value);
	return ((uint64_t)low << 32) | high;
}

static uint64_t be64_to_host(uint64_t value)
{
	return host_to_be64(value);
}

static int exact_pread(int fd, void *buffer, size_t size, off_t offset)
{
	uint8_t *cursor = buffer;
	while (size > 0) {
		ssize_t count = pread(fd, cursor, size, offset);
		if (count < 0 && errno == EINTR)
			continue;
		if (count <= 0)
			return EIO;
		cursor += count;
		offset += count;
		size -= (size_t)count;
	}
	return EOK;
}

static int exact_pwrite(int fd, const void *buffer, size_t size, off_t offset)
{
	const uint8_t *cursor = buffer;
	while (size > 0) {
		ssize_t count = pwrite(fd, cursor, size, offset);
		if (count < 0 && errno == EINTR)
			continue;
		if (count <= 0)
			return EIO;
		cursor += count;
		offset += count;
		size -= (size_t)count;
	}
	return EOK;
}

static bool image_range(struct ext4_blockdev *device, uint64_t block,
		uint32_t count, off_t *offset, size_t *length)
{
	uint64_t block_size = device->bdif->ph_bsize;
	if (block > UINT64_MAX / block_size ||
		(uint64_t)count > UINT64_MAX / block_size)
		return false;

	uint64_t begin = block * block_size;
	uint64_t bytes = (uint64_t)count * block_size;
	if (begin > device->part_size || bytes > device->part_size - begin ||
		begin > INT64_MAX || bytes > SIZE_MAX)
		return false;

	*offset = (off_t)(device->part_offset + begin);
	*length = (size_t)bytes;
	return true;
}

static int image_open(struct ext4_blockdev *device)
{
	struct stat status;
	if (member_image_fd < 0 || fstat(member_image_fd, &status) != 0 ||
		status.st_size < (off_t)(2 * ANDOCK_IMAGE_BLOCK_SIZE))
		return EIO;

	device->part_offset = 0;
	device->part_size = (uint64_t)status.st_size;
	device->bdif->ph_bcnt = device->part_size / device->bdif->ph_bsize;
	return EOK;
}

static int image_read(struct ext4_blockdev *device, void *buffer,
		uint64_t block, uint32_t count)
{
	off_t offset;
	size_t length;
	if (!image_range(device, block, count, &offset, &length))
		return EIO;
	return length == 0 ? EOK :
		exact_pread(member_image_fd, buffer, length, offset);
}

static int image_write(struct ext4_blockdev *device, const void *buffer,
		uint64_t block, uint32_t count)
{
	off_t offset;
	size_t length;
	if (!image_range(device, block, count, &offset, &length))
		return EIO;
	return length == 0 ? EOK :
		exact_pwrite(member_image_fd, buffer, length, offset);
}

static int image_close(struct ext4_blockdev *device)
{
	(void)device;
	return member_image_fd >= 0 && fsync(member_image_fd) != 0 ? EIO : EOK;
}

static void reset_device(void)
{
	member_image.part_offset = 0;
	member_image.part_size = 0;
	member_image.bc = NULL;
	member_image.lg_bsize = 0;
	member_image.lg_bcnt = 0;
	member_image.cache_write_back = 0;
	member_image.fs = NULL;
	member_image.journal = NULL;
	member_image.bdif->ph_bcnt = 0;
	member_image.bdif->ph_refctr = 0;
	member_image.bdif->bread_ctr = 0;
	member_image.bdif->bwrite_ctr = 0;
}

static struct cached_inode *find_cached_inode(uint64_t inode)
{
	struct cached_inode *entry = inode_cache;
	while (entry != NULL) {
		if (entry->inode == inode && !entry->unlinked)
			return entry;
		entry = entry->next;
	}
	return NULL;
}

static struct cached_inode *find_cached_id(uint64_t cache_id)
{
	struct cached_inode *entry = inode_cache;
	while (entry != NULL) {
		if (entry->cache_id == cache_id)
			return entry;
		entry = entry->next;
	}
	return NULL;
}

static void clear_dirty_ranges(struct cached_inode *cached)
{
	while (cached->dirty_ranges != NULL) {
		struct dirty_range *range = cached->dirty_ranges;
		cached->dirty_ranges = range->next;
		free(range);
	}
}

static int add_dirty_range(struct cached_inode *cached, uint64_t start,
		uint64_t length)
{
	if (length == 0)
		return 0;
	if (start > UINT64_MAX - length)
		return -EOVERFLOW;
	struct dirty_range *range = malloc(sizeof(*range));
	if (range == NULL)
		return -ENOMEM;
	uint64_t end = start + length;
	struct dirty_range **cursor = &cached->dirty_ranges;
	while (*cursor != NULL && (*cursor)->end < start)
		cursor = &(*cursor)->next;
	while (*cursor != NULL && (*cursor)->start <= end) {
		struct dirty_range *overlap = *cursor;
		if (overlap->start < start)
			start = overlap->start;
		if (overlap->end > end)
			end = overlap->end;
		*cursor = overlap->next;
		free(overlap);
	}
	range->start = start;
	range->end = end;
	range->next = *cursor;
	*cursor = range;
	return 0;
}

static void remove_cached_inode(struct cached_inode *cached)
{
	struct cached_inode **cursor = &inode_cache;
	while (*cursor != NULL) {
		if (*cursor == cached) {
			*cursor = cached->next;
			close(cached->memory_fd);
			clear_dirty_ranges(cached);
			free(cached);
			return;
		}
		cursor = &(*cursor)->next;
	}
}

static void clear_inode_cache(void)
{
	while (inode_cache != NULL) {
		struct cached_inode *entry = inode_cache;
		inode_cache = entry->next;
		close(entry->memory_fd);
		clear_dirty_ranges(entry);
		free(entry);
	}
}

int andock_image_engine_start(int image_fd)
{
	if (member_image_fd >= 0)
		return -EBUSY;
	inode_cache = NULL;
	socket_reservations = NULL;
	materialization_count = 0;
	next_cache_id = 0;
	next_socket_token = 0;
	latest_lookup.valid = false;
	clear_directory_cache();
	member_image_fd = fcntl(image_fd, F_DUPFD_CLOEXEC, 0);
	if (member_image_fd < 0)
		return -errno;

	reset_device();
	ext4_device_unregister_all();
	int result = ext4_device_register(&member_image, ANDOCK_IMAGE_DEVICE);
	if (result == EOK)
		result = ext4_mount(ANDOCK_IMAGE_DEVICE, ANDOCK_IMAGE_MOUNT, false);
	if (result == EOK)
		result = ext4_recover(ANDOCK_IMAGE_MOUNT);
	if (result == EOK)
		result = ext4_journal_start(ANDOCK_IMAGE_MOUNT);
	if (result != EOK) {
		ext4_umount(ANDOCK_IMAGE_MOUNT);
		ext4_device_unregister_all();
		close(member_image_fd);
		member_image_fd = -1;
		return -result;
	}
	return 0;
}

int andock_image_engine_flush(void)
{
	if (member_image_fd < 0)
		return -ENODEV;
	int result = ext4_cache_flush(ANDOCK_IMAGE_MOUNT);
	if (result == EOK && fsync(member_image_fd) != 0)
		result = EIO;
	return result == EOK ? 0 : -result;
}

int andock_image_engine_stop(void)
{
	if (member_image_fd < 0)
		return 0;
	int result = andock_image_engine_sync_all();
	if (result < 0)
		result = -result;
	int journal_result = ext4_journal_stop(ANDOCK_IMAGE_MOUNT);
	if (result == EOK)
		result = journal_result;
	int unmount_result = ext4_umount(ANDOCK_IMAGE_MOUNT);
	ext4_device_unregister_all();
	clear_inode_cache();
	clear_socket_reservations();
	if (close(member_image_fd) != 0 && result == EOK)
		result = EIO;
	member_image_fd = -1;
	if (result == EOK)
		result = unmount_result;
	return result == EOK ? 0 : -result;
}

static int mount_path(const char *guest, char output[PATH_MAX])
{
	if (guest == NULL || guest[0] != '/')
		return -EINVAL;
	int length = snprintf(output, PATH_MAX, "%s%s",
		ANDOCK_IMAGE_MOUNT, guest + 1);
	return length < 0 || length >= PATH_MAX ? -ENAMETOOLONG : 0;
}

static void path_pop(char path[PATH_MAX])
{
	char *slash = strrchr(path, '/');
	if (slash == NULL || slash == path)
		strcpy(path, "/");
	else
		*slash = '\0';
}

static int path_push(char path[PATH_MAX], const char *component, size_t length)
{
	if (length == 0 || length > 255)
		return -ENAMETOOLONG;
	size_t current = strlen(path);
	size_t separator = current == 1 ? 0 : 1;
	if (current + separator + length >= PATH_MAX)
		return -ENAMETOOLONG;
	if (separator)
		path[current++] = '/';
	memcpy(path + current, component, length);
	path[current + length] = '\0';
	return 0;
}

static int raw_inode(const char *guest, struct raw_lookup **lookup)
{
	if (reuse_latest_lookup && latest_lookup.valid
	    && strcmp(latest_lookup.path, guest) == 0) {
		*lookup = &latest_lookup;
		return 0;
	}
	char path[PATH_MAX];
	int status = mount_path(guest, path);
	if (status < 0)
		return status;
	int ext4_result = ext4_raw_inode_fill(path, &latest_lookup.inode_number,
		&latest_lookup.inode);
	if (ext4_result != EOK)
		return -ext4_result;
	if (member_image.fs == NULL)
		return -EIO;
	latest_lookup.mode = ext4_inode_get_mode(
		&member_image.fs->sb, &latest_lookup.inode);
	strcpy(latest_lookup.path, guest);
	latest_lookup.valid = true;
	*lookup = &latest_lookup;
	return 0;
}

static int raw_type(const char *guest, int *type)
{
	if (cached_directory(guest)) {
		*type = ANDOCK_IMAGE_DIRECTORY;
		return 0;
	}
	struct raw_lookup *lookup;
	int status = raw_inode(guest, &lookup);
	if (status < 0)
		return status;
	switch (lookup->mode & EXT4_INODE_MODE_TYPE_MASK) {
	case EXT4_INODE_MODE_SOFTLINK:
		*type = ANDOCK_IMAGE_SYMLINK;
		break;
	case EXT4_INODE_MODE_DIRECTORY:
		*type = ANDOCK_IMAGE_DIRECTORY;
		cache_directory(guest);
		break;
	case EXT4_INODE_MODE_FILE:
		*type = ANDOCK_IMAGE_FILE;
		break;
	case EXT4_INODE_MODE_SOCKET:
		*type = ANDOCK_IMAGE_SOCKET;
		break;
	default:
		*type = ANDOCK_IMAGE_OTHER;
		break;
	}
	return 0;
}

static int raw_readlink(const char *guest, char output[PATH_MAX])
{
	char path[PATH_MAX];
	int status = mount_path(guest, path);
	if (status < 0)
		return status;
	size_t length = 0;
	int result = ext4_readlink(path, output, PATH_MAX - 1, &length);
	if (result != EOK)
		return -result;
	if (length >= PATH_MAX)
		return -ENAMETOOLONG;
	output[length] = '\0';
	return 0;
}

static int resolve_guest(const char *input, bool dereference_final,
		bool allow_missing_final, char output[PATH_MAX], int *output_type)
{
	if (input == NULL || input[0] != '/' || strlen(input) >= PATH_MAX)
		return -EINVAL;
	char pending[PATH_MAX];
	strcpy(pending, input + 1);
	strcpy(output, "/");
	int symlinks = 0;

	while (pending[0] != '\0') {
		char *slash = strchr(pending, '/');
		size_t length = slash == NULL ? strlen(pending) :
			(size_t)(slash - pending);
		char remaining[PATH_MAX];
		if (slash == NULL)
			remaining[0] = '\0';
		else
			strcpy(remaining, slash + 1);
		while (remaining[0] == '/')
			memmove(remaining, remaining + 1, strlen(remaining));

		if (length == 0 || (length == 1 && pending[0] == '.')) {
			strcpy(pending, remaining);
			continue;
		}
		if (length == 2 && pending[0] == '.' && pending[1] == '.') {
			path_pop(output);
			strcpy(pending, remaining);
			continue;
		}

		char candidate[PATH_MAX];
		strcpy(candidate, output);
		int status = path_push(candidate, pending, length);
		if (status < 0)
			return status;
		int type;
		status = raw_type(candidate, &type);
		bool final = remaining[0] == '\0';
		if (status == -ENOENT && final && allow_missing_final) {
			strcpy(output, candidate);
			*output_type = ANDOCK_IMAGE_MISSING;
			return 0;
		}
		if (status < 0)
			return status;
		if (type == ANDOCK_IMAGE_SYMLINK &&
			(!final || dereference_final)) {
			if (++symlinks > ANDOCK_IMAGE_MAX_SYMLINKS)
				return -ELOOP;
			char target[PATH_MAX];
			status = raw_readlink(candidate, target);
			if (status < 0)
				return status;
			if (target[0] == '/')
				strcpy(output, "/");
			int written = snprintf(pending, PATH_MAX, "%s%s%s",
				target,
				target[0] != '\0' && remaining[0] != '\0' ? "/" : "",
				remaining);
			if (written < 0 || written >= PATH_MAX)
				return -ENAMETOOLONG;
			while (pending[0] == '/')
				memmove(pending, pending + 1, strlen(pending));
			continue;
		}
		if (!final && type != ANDOCK_IMAGE_DIRECTORY)
			return -ENOTDIR;
		strcpy(output, candidate);
		strcpy(pending, remaining);
		if (final) {
			*output_type = type;
			return 0;
		}
	}
	*output_type = ANDOCK_IMAGE_DIRECTORY;
	return 0;
}

static void result_init(struct andock_image_result *result)
{
	memset(result, 0, sizeof(*result));
	result->guest_fd = -1;
	result->backing_fd = -1;
}

void andock_image_result_release(struct andock_image_result *result)
{
	if (result == NULL)
		return;
	if (result->guest_fd >= 0)
		close(result->guest_fd);
	if (result->backing_fd >= 0)
		close(result->backing_fd);
	free(result->path);
	free(result->data);
	result_init(result);
}

static int result_path(struct andock_image_result *result, const char *path)
{
	result->path = strdup(path);
	return result->path == NULL ? -ENOMEM : 0;
}

static int result_data(struct andock_image_result *result,
		const void *data, size_t size)
{
	if (size == 0)
		return 0;
	result->data = malloc(size);
	if (result->data == NULL)
		return -ENOMEM;
	memcpy(result->data, data, size);
	result->data_size = size;
	return 0;
}

static int metadata(const char *guest, int type,
		struct andock_image_result *result)
{
	struct raw_lookup *lookup;
	int status = raw_inode(guest, &lookup);
	if (status < 0)
		return status;
	uint32_t mode = lookup->mode;
	result->type = type;
	result->mode = mode;
	switch (type) {
	case ANDOCK_IMAGE_FILE:
		result->mode = (mode & 07777) | S_IFREG;
		break;
	case ANDOCK_IMAGE_DIRECTORY:
		result->mode = (mode & 07777) | S_IFDIR;
		break;
	case ANDOCK_IMAGE_SYMLINK:
		result->mode = (mode & 07777) | S_IFLNK;
		break;
	case ANDOCK_IMAGE_SOCKET:
		result->mode = (mode & 07777) | S_IFSOCK;
		break;
	default:
		result->mode = mode;
		break;
	}

	result->inode = lookup->inode_number;
	result->links = ext4_inode_get_links_cnt(&lookup->inode);
	result->atime = ext4_inode_get_access_time(&lookup->inode);
	result->mtime = ext4_inode_get_modif_time(&lookup->inode);
	result->ctime = ext4_inode_get_change_inode_time(&lookup->inode);
	if (type == ANDOCK_IMAGE_FILE) {
		struct cached_inode *cached = find_cached_inode(lookup->inode_number);
		if (cached != NULL) {
			struct stat status;
			if (fstat(cached->memory_fd, &status) != 0)
				return -errno;
			result->size = status.st_size;
			result->atime = cached->atime;
			result->mtime = cached->mtime;
			result->ctime = cached->ctime;
		} else
			result->size = ext4_inode_get_size(
				&member_image.fs->sb, &lookup->inode);
	} else if (type == ANDOCK_IMAGE_SYMLINK) {
		result->size = ext4_inode_get_size(
			&member_image.fs->sb, &lookup->inode);
	}
	return result_path(result, guest);
}

int andock_image_engine_reopen(int fd, int flags)
{
#ifdef __ANDROID__
	/* Android's isolated_app domain denies reopening /proc/self/fd.  The
	 * extension mediates every carrier operation and keeps the requested
	 * access mode in the logical open description. */
	(void)flags;
	int duplicate = fcntl(fd, F_DUPFD_CLOEXEC, 0);
	return duplicate < 0 ? -errno : duplicate;
#else
	char path[64];
	int reopened_flags = flags & (O_ACCMODE | O_APPEND | O_CLOEXEC
		| O_NONBLOCK | O_TRUNC);
#ifdef O_DIRECT
	reopened_flags |= flags & O_DIRECT;
#endif
#ifdef O_DSYNC
	reopened_flags |= flags & O_DSYNC;
#endif
#ifdef O_NOATIME
	reopened_flags |= flags & O_NOATIME;
#endif
#ifdef O_PATH
	if ((flags & O_PATH) != 0)
		reopened_flags = O_PATH | (flags & O_CLOEXEC);
#endif
#ifdef O_SYNC
	reopened_flags |= flags & O_SYNC;
#endif
	int length = snprintf(path, sizeof(path), "/proc/self/fd/%d", fd);
	if (length < 0 || (size_t)length >= sizeof(path))
		return -EOVERFLOW;
	int reopened = open(path, reopened_flags);
	return reopened < 0 ? -errno : reopened;
#endif
}

static bool buffer_has_nonzero_byte(const uint8_t *buffer, size_t size)
{
	for (size_t index = 0; index < size; index++) {
		if (buffer[index] != 0)
			return true;
	}
	return false;
}

static int ensure_host_storage(size_t upcoming)
{
	struct statvfs status;
	if (fstatvfs(member_image_fd, &status) != 0)
		return -errno;
	uint64_t fragment_size = status.f_frsize == 0
		? status.f_bsize : status.f_frsize;
	if (fragment_size != 0
	    && status.f_bavail > UINT64_MAX / fragment_size)
		return 0;
	uint64_t available = status.f_bavail * fragment_size;
	return available >= ANDOCK_IMAGE_HOST_FREE_RESERVE_BYTES
		&& upcoming <= available - ANDOCK_IMAGE_HOST_FREE_RESERVE_BYTES
		? 0 : -ENOSPC;
}

struct materialize_context {
	ext4_file *file;
	int memory_fd;
	uint8_t *buffer;
	uint64_t size;
	uint32_t block_size;
};

static int materialize_extent(ext4_lblk_t logical_block,
		uint32_t block_count, void *argument)
{
	struct materialize_context *context = argument;
	uint64_t offset = (uint64_t)logical_block * context->block_size;
	uint64_t end = offset + (uint64_t)block_count * context->block_size;
	if (offset >= context->size)
		return EOK;
	if (end > context->size)
		end = context->size;
	int result = ext4_fseek(context->file, (int64_t)offset, SEEK_SET);
	if (result != EOK)
		return result;
	while (offset < end) {
		size_t wanted = end - offset > ANDOCK_IMAGE_IO_BYTES
			? ANDOCK_IMAGE_IO_BYTES : (size_t)(end - offset);
		size_t read = 0;
		result = ext4_fread(context->file, context->buffer, wanted, &read);
		if (result != EOK || read != wanted)
			return result == EOK ? EIO : result;
		for (size_t block = 0; block < read;
			block += ANDOCK_IMAGE_SPARSE_BLOCK_BYTES) {
			size_t block_bytes = read - block > ANDOCK_IMAGE_SPARSE_BLOCK_BYTES
				? ANDOCK_IMAGE_SPARSE_BLOCK_BYTES : read - block;
			if (buffer_has_nonzero_byte(context->buffer + block, block_bytes)
			    && exact_pwrite(context->memory_fd, context->buffer + block,
				block_bytes, (off_t)(offset + block)) != EOK)
				return EIO;
		}
		offset += read;
	}
	return EOK;
}

static int load_cached_inode(const char *guest,
		struct andock_image_result *result, struct cached_inode **output)
{
	struct cached_inode *cached = find_cached_inode(result->inode);
	if (cached != NULL) {
		result->cache_id = cached->cache_id;
		*output = cached;
		return 0;
	}
	char path[PATH_MAX];
	int status = mount_path(guest, path);
	if (status < 0)
		return status;
	ext4_file file;
	int ext4_result = ext4_fopen(&file, path, "r");
	if (ext4_result != EOK) {
		dprintf(STDERR_FILENO,
			"andock: materialize %s: ext4 open failed: %s (%d)\n",
			guest, strerror(ext4_result), -ext4_result);
		return -ext4_result;
	}
	uint64_t size = ext4_fsize(&file);
	if (size > (uint64_t)INT64_MAX) {
		ext4_fclose(&file);
		return -EFBIG;
	}
	int memory_fd = create_memory_file("andock-file",
		MFD_CLOEXEC | MFD_ALLOW_SEALING | MFD_EXEC);
	if (memory_fd < 0) {
		status = -errno;
		dprintf(STDERR_FILENO,
			"andock: materialize %s: memfd_create failed: %s (%d)\n",
			guest, strerror(-status), status);
		ext4_fclose(&file);
		return status;
	}
	if (ftruncate(memory_fd, (off_t)size) != 0) {
		status = -errno;
		dprintf(STDERR_FILENO,
			"andock: materialize %s: ftruncate failed: %s (%d)\n",
			guest, strerror(-status), status);
		close(memory_fd);
		ext4_fclose(&file);
		return status;
	}
	uint8_t *buffer = malloc(ANDOCK_IMAGE_IO_BYTES);
	if (buffer == NULL) {
		close(memory_fd);
		ext4_fclose(&file);
		return -ENOMEM;
	}
	struct ext4_inode_ref inode_ref;
	ext4_result = ext4_fs_get_inode_ref(
		member_image.fs, (uint32_t)result->inode, &inode_ref);
	if (ext4_result != EOK)
		status = -ext4_result;
	if (status == 0) {
		bool extent_backed = ext4_sb_feature_incom(
			&member_image.fs->sb, EXT4_FINCOM_EXTENTS)
			&& ext4_inode_has_flag(inode_ref.inode, EXT4_INODE_FLAG_EXTENTS);
		if (extent_backed) {
			struct materialize_context context = {
				.file = &file,
				.memory_fd = memory_fd,
				.buffer = buffer,
				.size = size,
				.block_size = ext4_sb_get_block_size(&member_image.fs->sb),
			};
			ext4_result = ext4_extent_visit_data(
				&inode_ref, materialize_extent, &context);
			if (ext4_result != EOK)
				status = -ext4_result;
		} else {
			off_t offset = 0;
			while ((uint64_t)offset < size) {
				size_t wanted = size - (uint64_t)offset > ANDOCK_IMAGE_IO_BYTES
					? ANDOCK_IMAGE_IO_BYTES
					: (size_t)(size - (uint64_t)offset);
				size_t read = 0;
				ext4_result = ext4_fread(&file, buffer, wanted, &read);
				if (ext4_result != EOK || read != wanted) {
					status = ext4_result == EOK ? -EIO : -ext4_result;
					break;
				}
				for (size_t block = 0; block < read;
					block += ANDOCK_IMAGE_SPARSE_BLOCK_BYTES) {
					size_t block_bytes = read - block
						> ANDOCK_IMAGE_SPARSE_BLOCK_BYTES
						? ANDOCK_IMAGE_SPARSE_BLOCK_BYTES : read - block;
					if (buffer_has_nonzero_byte(buffer + block, block_bytes)
					    && exact_pwrite(memory_fd, buffer + block, block_bytes,
						offset + (off_t)block) != EOK) {
						status = -EIO;
						break;
					}
				}
				if (status < 0)
					break;
				offset += (off_t)read;
			}
		}
		ext4_result = ext4_fs_put_inode_ref(&inode_ref);
		if (status == 0 && ext4_result != EOK)
			status = -ext4_result;
	}
	if (status < 0)
		dprintf(STDERR_FILENO,
			"andock: materialize %s failed: %s (%d)\n",
			guest, strerror(-status), status);
	free(buffer);
	ext4_fclose(&file);
	/*
	 * Android's isolated_app domain deliberately denies setattr on executable
	 * MFD_EXEC files.  The memfd is only an execution and I/O carrier; guest
	 * metadata remains authoritative in ext4 and is reported by the PRoot
	 * extension rather than being copied onto this host object.
	 */
	if (status < 0) {
		close(memory_fd);
		return status;
	}
	cached = calloc(1, sizeof(*cached));
	if (cached == NULL) {
		close(memory_fd);
		return -ENOMEM;
	}
	cached->inode = result->inode;
	if (next_cache_id == UINT64_MAX) {
		close(memory_fd);
		free(cached);
		return -EOVERFLOW;
	}
	cached->cache_id = ++next_cache_id;
	cached->memory_fd = memory_fd;
	cached->persisted_size = size;
	cached->atime = result->atime;
	cached->mtime = result->mtime;
	cached->ctime = result->ctime;
	cached->next = inode_cache;
	inode_cache = cached;
	materialization_count++;
	result->cache_id = cached->cache_id;
	*output = cached;
	return 0;
}

static int materialize(const char *guest, int flags, bool tracked,
		struct andock_image_result *result)
{
	struct cached_inode *cached;
	int status = load_cached_inode(guest, result, &cached);
	if (status < 0)
		return status;
	int guest_fd = andock_image_engine_reopen(cached->memory_fd, flags);
	if (guest_fd < 0) {
		dprintf(STDERR_FILENO,
			"andock: materialize %s: memfd duplicate failed: %s (%d)\n",
			guest, strerror(-guest_fd), guest_fd);
		return guest_fd;
	}
	result->guest_fd = guest_fd;
	if (tracked) {
		result->backing_fd = fcntl(
			cached->memory_fd, F_DUPFD_CLOEXEC, 0);
		if (result->backing_fd < 0) {
			status = -errno;
			close(result->guest_fd);
			result->guest_fd = -1;
			return status;
		}
	}
	return 0;
}

static int resolve_operation(int flags, const char *path,
		struct andock_image_result *result)
{
	char resolved[PATH_MAX];
	int type;
	int status = resolve_guest(
		path,
		(flags & ANDOCK_IMAGE_DEREFERENCE_FINAL) != 0,
		(flags & ANDOCK_IMAGE_ALLOW_MISSING_FINAL) != 0,
		resolved,
		&type
	);
	if (status < 0)
		return status;
	if (type == ANDOCK_IMAGE_MISSING) {
		result->type = type;
		return result_path(result, resolved);
	}
	status = metadata(resolved, type, result);
	if (status < 0)
		return status;
	if ((flags & ANDOCK_IMAGE_EXECUTABLE) != 0 &&
		(type != ANDOCK_IMAGE_FILE || (result->mode & 0111) == 0))
		return -EACCES;
	if (type == ANDOCK_IMAGE_FILE
	    && (flags & ANDOCK_IMAGE_EXECUTABLE) != 0) {
		status = materialize(resolved, O_RDONLY | O_CLOEXEC, false, result);
		if (status == 0) {
			struct cached_inode *cached = find_cached_id(result->cache_id);
			if (cached != NULL && cached->references == 0
			    && !cached->dirty) {
				remove_cached_inode(cached);
				result->cache_id = 0;
			}
		}
	}
	else if (type == ANDOCK_IMAGE_SYMLINK) {
		char link[PATH_MAX];
		status = raw_readlink(resolved, link);
		if (status == 0)
			status = result_data(result, link, strlen(link));
	}
	return status;
}

static int open_operation(int flags, mode_t mode, const char *path,
		struct andock_image_result *result)
{
	char resolved[PATH_MAX];
	int type;
	bool create = (flags & O_CREAT) != 0;
	bool created;
	int status = resolve_guest(path, (flags & O_NOFOLLOW) == 0,
		create, resolved, &type);
	if (status < 0)
		return status;
	if (type == ANDOCK_IMAGE_DIRECTORY)
		return -EISDIR;
	if (type == ANDOCK_IMAGE_SYMLINK && (flags & O_NOFOLLOW) != 0)
		return -ELOOP;
	if (type != ANDOCK_IMAGE_MISSING && create && (flags & O_EXCL) != 0)
		return -EEXIST;
	if (type == ANDOCK_IMAGE_OTHER)
		return -ENXIO;
	created = type == ANDOCK_IMAGE_MISSING;

	char image_path_buffer[PATH_MAX];
	status = mount_path(resolved, image_path_buffer);
	if (status < 0)
		return status;
	int image_flags = flags & (O_ACCMODE | O_CREAT | O_EXCL | O_TRUNC | O_APPEND);
	ext4_file file = {0};
	int ext4_result = ext4_fopen2(&file, image_path_buffer, image_flags);
	if (ext4_result != EOK)
		return -ext4_result;
	ext4_fclose(&file);
	if (type == ANDOCK_IMAGE_MISSING) {
		ext4_result = ext4_mode_set(image_path_buffer, mode & 07777);
		if (ext4_result != EOK)
			return -ext4_result;
	}
	status = metadata(resolved, ANDOCK_IMAGE_FILE, result);
	if (status < 0)
		return status;
	struct cached_inode *cached = find_cached_inode(result->inode);
	if (created && cached != NULL) {
		cached->unlinked = true;
		if (cached->references == 0)
			remove_cached_inode(cached);
		cached = NULL;
	}
	if (cached != NULL && (flags & O_TRUNC) != 0) {
		if (ftruncate(cached->memory_fd, 0) != 0)
			return -errno;
		cached->dirty = true;
	}
	return materialize(resolved, flags, true, result);
}

static int refresh_cached_timestamps(struct cached_inode *cached)
{
	struct stat status;
	if (fstat(cached->memory_fd, &status) != 0)
		return -errno;
	cached->atime = status.st_atim.tv_sec;
	cached->mtime = status.st_mtim.tv_sec;
	cached->ctime = status.st_ctim.tv_sec;
	cached->timestamps_explicit = false;
	return 0;
}

static int write_ext4_range(ext4_file *file, int memory_fd, uint8_t *buffer,
		uint64_t start, uint64_t end)
{
	if (start >= end)
		return 0;
	int ext4_result = ext4_fseek(file, (int64_t)start, SEEK_SET);
	if (ext4_result != EOK)
		return -ext4_result;
	uint64_t offset = start;
	while (offset < end) {
		size_t wanted = end - offset > ANDOCK_IMAGE_IO_BYTES
			? ANDOCK_IMAGE_IO_BYTES : (size_t)(end - offset);
		int capacity = ensure_host_storage(wanted);
		if (capacity < 0)
			return capacity;
		if (exact_pread(memory_fd, buffer, wanted, (off_t)offset) != EOK)
			return -EIO;
		size_t written = 0;
		ext4_result = ext4_fwrite(file, buffer, wanted, &written);
		if (ext4_result != EOK || written != wanted)
			return ext4_result == EOK ? -EIO : -ext4_result;
		offset += written;
	}
	return 0;
}

static int reset_sparse_inode(ext4_file *file, struct cached_inode *cached,
		uint64_t size)
{
	int ext4_result = ext4_ftruncate(file, 0);
	if (ext4_result != EOK)
		return -ext4_result;
	ext4_result = ext4_fclose(file);
	if (ext4_result != EOK)
		return -ext4_result;
	if (size != 0) {
		ext4_result = ext4_inode_sparse_size_set(
			ANDOCK_IMAGE_MOUNT, (uint32_t)cached->inode, size);
		if (ext4_result != EOK)
			return -ext4_result;
	}
	ext4_result = ext4_fopen_inode(
		file, ANDOCK_IMAGE_MOUNT, (uint32_t)cached->inode, O_RDWR);
	return ext4_result == EOK ? 0 : -ext4_result;
}

static int write_sparse_memfd(ext4_file *file, struct cached_inode *cached,
		uint8_t *buffer, uint64_t size)
{
	uint64_t offset = 0;
	while (offset < size) {
		errno = 0;
		off_t data = lseek(cached->memory_fd, (off_t)offset, SEEK_DATA);
		if (data < 0) {
			if (errno == ENXIO)
				return 0;
			if (errno == EINVAL || errno == ENOTSUP)
				return write_ext4_range(
					file, cached->memory_fd, buffer, 0, size);
			return -errno;
		}
		if ((uint64_t)data >= size)
			return 0;
		off_t hole = lseek(cached->memory_fd, data, SEEK_HOLE);
		if (hole < 0)
			return -errno;
		uint64_t end = (uint64_t)hole > size ? size : (uint64_t)hole;
		int status = write_ext4_range(
			file, cached->memory_fd, buffer, (uint64_t)data, end);
		if (status < 0)
			return status;
		offset = end;
	}
	return 0;
}

static int writeback_cached_inode(struct cached_inode *cached)
{
	if (member_image_fd < 0 || cached == NULL)
		return -EINVAL;
	struct stat status;
	if (fstat(cached->memory_fd, &status) != 0 || status.st_size < 0)
		return -errno;
	int result = 0;
	ext4_file file;
	int ext4_result = ext4_fopen_inode(
		&file, ANDOCK_IMAGE_MOUNT, (uint32_t)cached->inode, O_RDWR);
	if (ext4_result != EOK)
		return cached->unlinked ? 0 : -ext4_result;
	uint8_t *buffer = malloc(ANDOCK_IMAGE_IO_BYTES);
	if (buffer == NULL) {
		ext4_fclose(&file);
		return -ENOMEM;
	}
	uint64_t size = (uint64_t)status.st_size;
	if (cached->full_dirty || size != cached->persisted_size) {
		result = reset_sparse_inode(&file, cached, size);
		if (result == 0)
			result = write_sparse_memfd(&file, cached, buffer, size);
	} else {
		struct dirty_range *range = cached->dirty_ranges;
		while (range != NULL && result == 0) {
			uint64_t end = range->end > size ? size : range->end;
			result = write_ext4_range(
				&file, cached->memory_fd, buffer, range->start, end);
			range = range->next;
		}
	}
	free(buffer);
	ext4_result = file.mp == NULL ? EOK : ext4_fclose(&file);
	if (result == 0 && ext4_result != EOK)
		result = -ext4_result;
	if (result == 0) {
		ext4_result = ext4_inode_times_set(
			ANDOCK_IMAGE_MOUNT, (uint32_t)cached->inode,
			(uint32_t)cached->atime,
			(uint32_t)cached->mtime,
			(uint32_t)cached->ctime);
		if (ext4_result != EOK)
			result = -ext4_result;
	}
	if (result == 0) {
		cached->persisted_size = size;
		cached->full_dirty = false;
		clear_dirty_ranges(cached);
	}
	return result;
}

int andock_image_engine_retain(uint64_t cache_id)
{
	if (cache_id == 0)
		return 0;
	struct cached_inode *cached = find_cached_id(cache_id);
	if (cached == NULL)
		return -ENOENT;
	if (cached->references == UINT_MAX)
		return -EOVERFLOW;
	cached->references++;
	return 0;
}

int andock_image_engine_mark_dirty(uint64_t cache_id)
{
	struct cached_inode *cached = find_cached_id(cache_id);
	if (cached == NULL)
		return -ENOENT;
	int status = refresh_cached_timestamps(cached);
	if (status < 0)
		return status;
	cached->dirty = true;
	cached->full_dirty = true;
	clear_dirty_ranges(cached);
	return 0;
}

int andock_image_engine_mark_dirty_range(uint64_t cache_id,
		uint64_t offset, uint64_t length)
{
	struct cached_inode *cached = find_cached_id(cache_id);
	if (cached == NULL)
		return -ENOENT;
	int status = refresh_cached_timestamps(cached);
	if (status < 0)
		return status;
	status = cached->full_dirty ? 0 : add_dirty_range(cached, offset, length);
	if (status == 0 && length != 0)
		cached->dirty = true;
	return status;
}

int andock_image_engine_mapping_retain(uint64_t cache_id, bool writable)
{
	struct cached_inode *cached = find_cached_id(cache_id);
	if (cached == NULL)
		return -ENOENT;
	if (cached->mappings == UINT_MAX
	    || (writable && cached->writable_mappings == UINT_MAX))
		return -EOVERFLOW;
	int status = andock_image_engine_retain(cache_id);
	if (status < 0)
		return status;
	cached->mappings++;
	if (writable) {
		status = andock_image_engine_mark_dirty(cache_id);
		if (status < 0) {
			cached->mappings--;
			andock_image_engine_release(cache_id);
			return status;
		}
		cached->writable_mappings++;
	}
	return 0;
}

int andock_image_engine_mapping_release(uint64_t cache_id, bool writable)
{
	struct cached_inode *cached = find_cached_id(cache_id);
	if (cached == NULL)
		return -ENOENT;
	if (cached->mappings == 0
	    || (writable && cached->writable_mappings == 0))
		return -EINVAL;
	int status = writable ? andock_image_engine_mark_dirty(cache_id) : 0;
	cached->mappings--;
	if (writable)
		cached->writable_mappings--;
	int release_status = andock_image_engine_release(cache_id);
	return status < 0 ? status : release_status;
}

int andock_image_engine_timestamps(uint64_t cache_id,
		int64_t *atime, int64_t *mtime, int64_t *ctime)
{
	struct cached_inode *cached = find_cached_id(cache_id);
	if (cached == NULL || atime == NULL || mtime == NULL || ctime == NULL)
		return -EINVAL;
	*atime = cached->atime;
	*mtime = cached->mtime;
	*ctime = cached->ctime;
	return 0;
}

static int sync_cached_inode(struct cached_inode *cached)
{
	if (cached == NULL || !cached->dirty)
		return 0;
	if (cached->unlinked) {
		cached->dirty = false;
		return 0;
	}
	int status = writeback_cached_inode(cached);
	if (status == 0)
		cached->dirty = false;
	return status;
}

int andock_image_engine_writeback(uint64_t cache_id)
{
	return sync_cached_inode(find_cached_id(cache_id));
}

int andock_image_engine_sync(uint64_t cache_id)
{
	int status = andock_image_engine_writeback(cache_id);
	return status < 0 ? status : andock_image_engine_flush();
}

int andock_image_engine_release(uint64_t cache_id)
{
	if (cache_id == 0)
		return 0;
	struct cached_inode *cached = find_cached_id(cache_id);
	if (cached == NULL)
		return -ENOENT;
	if (cached->references == 0)
		return -EINVAL;
	cached->references--;
	if (cached->references != 0)
		return 0;
	int status = sync_cached_inode(cached);
	/*
	 * The cache owns one memfd per materialized inode.  Keeping every clean,
	 * closed file resident eventually exhausts the isolated process fd limit
	 * during normal package and archive workloads.  Every tracked mapping owns
	 * its own reference, so reaching zero means no descriptor or mapping
	 * can still change the memfd.
	 */
	if (status == 0)
		remove_cached_inode(cached);
	return status;
}

int andock_image_engine_sync_all(void)
{
	int first_error = 0;
	struct cached_inode *cached = inode_cache;
	while (cached != NULL) {
		if (cached->writable_mappings != 0) {
			if (!cached->timestamps_explicit) {
				int status = refresh_cached_timestamps(cached);
				if (status < 0 && first_error == 0)
					first_error = status;
			}
			cached->dirty = true;
			cached->full_dirty = true;
			clear_dirty_ranges(cached);
		}
		int status = sync_cached_inode(cached);
		if (status < 0 && first_error == 0)
			first_error = status;
		cached = cached->next;
	}
	return first_error;
}

uint64_t andock_image_engine_materializations(void)
{
	return materialization_count;
}

static int readlink_operation(const char *path,
		struct andock_image_result *result)
{
	char resolved[PATH_MAX];
	int type;
	int status = resolve_guest(path, false, false, resolved, &type);
	if (status < 0)
		return status;
	if (type != ANDOCK_IMAGE_SYMLINK)
		return -EINVAL;
	char link[PATH_MAX];
	status = raw_readlink(resolved, link);
	if (status < 0)
		return status;
	result->type = type;
	status = result_path(result, resolved);
	return status < 0 ? status : result_data(result, link, strlen(link));
}

static int append_directory_entry(uint8_t **data, size_t *used,
		size_t *capacity, const ext4_direntry *entry)
{
	size_t needed = 4 + entry->name_length;
	if (*used > SIZE_MAX - needed)
		return -EOVERFLOW;
	if (*used + needed > *capacity) {
		size_t next = *capacity == 0 ? 4096 : *capacity;
		while (next < *used + needed) {
			if (next > SIZE_MAX / 2)
				return -EOVERFLOW;
			next *= 2;
		}
		uint8_t *resized = realloc(*data, next);
		if (resized == NULL)
			return -ENOMEM;
		*data = resized;
		*capacity = next;
	}
	uint16_t name_length = htons(entry->name_length);
	memcpy(*data + *used, &name_length, sizeof(name_length));
	int type;
	switch (entry->inode_type) {
	case EXT4_DE_REG_FILE: type = ANDOCK_IMAGE_FILE; break;
	case EXT4_DE_DIR: type = ANDOCK_IMAGE_DIRECTORY; break;
	case EXT4_DE_SYMLINK: type = ANDOCK_IMAGE_SYMLINK; break;
	case EXT4_DE_SOCK: type = ANDOCK_IMAGE_SOCKET; break;
	default: type = ANDOCK_IMAGE_OTHER; break;
	}
	(*data)[*used + 2] = (uint8_t)type;
	(*data)[*used + 3] = 0;
	memcpy(*data + *used + 4, entry->name, entry->name_length);
	*used += needed;
	return 0;
}

static int list_operation(const char *path,
		struct andock_image_result *result)
{
	char resolved[PATH_MAX];
	int type;
	int status = resolve_guest(path, true, false, resolved, &type);
	if (status < 0)
		return status;
	if (type != ANDOCK_IMAGE_DIRECTORY)
		return -ENOTDIR;
	char image_path_buffer[PATH_MAX];
	status = mount_path(resolved, image_path_buffer);
	if (status < 0)
		return status;
	ext4_dir directory;
	int ext4_result = ext4_dir_open(&directory, image_path_buffer);
	if (ext4_result != EOK)
		return -ext4_result;
	uint8_t *data = NULL;
	size_t used = 0;
	size_t capacity = 0;
	const ext4_direntry *entry;
	while ((entry = ext4_dir_entry_next(&directory)) != NULL) {
		if ((entry->name_length == 1 && entry->name[0] == '.') ||
			(entry->name_length == 2 && entry->name[0] == '.' &&
			 entry->name[1] == '.'))
			continue;
		status = append_directory_entry(&data, &used, &capacity, entry);
		if (status < 0)
			break;
	}
	ext4_dir_close(&directory);
	if (status < 0) {
		free(data);
		return status;
	}
	result->type = type;
	result->data = data;
	result->data_size = used;
	return result_path(result, resolved);
}

static int resolve_parent(const char *path, char resolved[PATH_MAX],
		char parent[PATH_MAX])
{
	int type;
	int status = resolve_guest(path, false, true, resolved, &type);
	if (status < 0)
		return status;
	strcpy(parent, resolved);
	path_pop(parent);
	int parent_type;
	status = raw_type(parent, &parent_type);
	if (status < 0)
		return status;
	return parent_type == ANDOCK_IMAGE_DIRECTORY ? 0 : -ENOTDIR;
}

static int mkdir_operation(mode_t mode, const char *path,
		struct andock_image_result *result)
{
	char resolved[PATH_MAX];
	char parent[PATH_MAX];
	int status = resolve_parent(path, resolved, parent);
	if (status < 0)
		return status;
	int type;
	if (raw_type(resolved, &type) == 0)
		return -EEXIST;
	char image_path_buffer[PATH_MAX];
	status = mount_path(resolved, image_path_buffer);
	if (status < 0)
		return status;
	int ext4_result = ext4_dir_mk(image_path_buffer);
	if (ext4_result == EOK)
		ext4_result = ext4_mode_set(image_path_buffer, mode & 07777);
	if (ext4_result != EOK)
		return -ext4_result;
	return metadata(resolved, ANDOCK_IMAGE_DIRECTORY, result);
}

static int directory_empty(const char *path)
{
	ext4_dir directory;
	int ext4_result = ext4_dir_open(&directory, path);
	if (ext4_result != EOK)
		return -ext4_result;
	const ext4_direntry *entry;
	int empty = 1;
	while ((entry = ext4_dir_entry_next(&directory)) != NULL) {
		if ((entry->name_length == 1 && entry->name[0] == '.')
		    || (entry->name_length == 2 && entry->name[0] == '.'
			&& entry->name[1] == '.'))
			continue;
		empty = 0;
		break;
	}
	ext4_result = ext4_dir_close(&directory);
	return ext4_result == EOK ? empty : -ext4_result;
}

static int socket_operation(mode_t mode, const char *path,
		struct andock_image_result *result)
{
	struct socket_reservation *reservation;
	char resolved[PATH_MAX];
	char parent[PATH_MAX];
	int status = resolve_parent(path, resolved, parent);
	if (status < 0)
		return status;
	int type;
	if (raw_type(resolved, &type) == 0)
		return -EEXIST;
	invalidate_socket_reservations(resolved);
	char image_path_buffer[PATH_MAX];
	status = mount_path(resolved, image_path_buffer);
	if (status < 0)
		return status;
	int ext4_result = ext4_mknod(image_path_buffer, EXT4_DE_SOCK, 0);
	if (ext4_result == EOK)
		ext4_result = ext4_mode_set(image_path_buffer, mode & 07777);
	if (ext4_result != EOK) {
		ext4_fremove(image_path_buffer);
		return -ext4_result;
	}
	status = metadata(resolved, ANDOCK_IMAGE_SOCKET, result);
	if (status < 0) {
		ext4_fremove(image_path_buffer);
		return status;
	}
	if (next_socket_token == UINT64_MAX) {
		ext4_fremove(image_path_buffer);
		return -EOVERFLOW;
	}
	reservation = calloc(1, sizeof(*reservation));
	if (reservation == NULL) {
		ext4_fremove(image_path_buffer);
		return -ENOMEM;
	}
	reservation->path = strdup(resolved);
	if (reservation->path == NULL) {
		free(reservation);
		ext4_fremove(image_path_buffer);
		return -ENOMEM;
	}
	reservation->token = ++next_socket_token;
	reservation->inode = result->inode;
	reservation->next = socket_reservations;
	socket_reservations = reservation;
	result->token = reservation->token;
	return 0;
}

static int socket_finish_operation(bool cancel, const void *data,
		size_t data_size, struct andock_image_result *result)
{
	if (data_size != sizeof(uint64_t))
		return -EINVAL;
	uint64_t token;
	memcpy(&token, data, sizeof(token));
	struct socket_reservation *reservation = find_socket_reservation(token);
	if (reservation == NULL)
		return 0;
	if (!cancel) {
		remove_socket_reservation(reservation);
		return 0;
	}
	char resolved[PATH_MAX];
	int type;
	int status = resolve_guest(
		reservation->path, false, false, resolved, &type);
	if (status == -ENOENT) {
		remove_socket_reservation(reservation);
		return 0;
	}
	if (status < 0)
		return status;
	if (type != ANDOCK_IMAGE_SOCKET) {
		remove_socket_reservation(reservation);
		return 0;
	}
	struct andock_image_result existing;
	result_init(&existing);
	status = metadata(resolved, type, &existing);
	if (status < 0)
		return status;
	if (existing.inode != reservation->inode) {
		andock_image_result_release(&existing);
		remove_socket_reservation(reservation);
		return 0;
	}
	andock_image_result_release(&existing);
	char image_path_buffer[PATH_MAX];
	status = mount_path(resolved, image_path_buffer);
	if (status < 0)
		return status;
	int ext4_result = ext4_fremove(image_path_buffer);
	if (ext4_result != EOK)
		return -ext4_result;
	remove_socket_reservation(reservation);
	return result_path(result, resolved);
}

static int unlink_operation(int flags, const char *path,
		struct andock_image_result *result)
{
	char resolved[PATH_MAX];
	int type;
	int status = resolve_guest(path, false, false, resolved, &type);
	if (status < 0)
		return status;
	bool remove_directory = (flags & AT_REMOVEDIR) != 0;
	if (remove_directory != (type == ANDOCK_IMAGE_DIRECTORY))
		return type == ANDOCK_IMAGE_DIRECTORY ? -EISDIR : -ENOTDIR;
	struct andock_image_result existing;
	result_init(&existing);
	status = metadata(resolved, type, &existing);
	if (status < 0)
		return status;
	struct cached_inode *cached = find_cached_inode(existing.inode);
	if (cached != NULL) {
		status = sync_cached_inode(cached);
		if (status < 0) {
			andock_image_result_release(&existing);
			return status;
		}
	}
	char image_path_buffer[PATH_MAX];
	status = mount_path(resolved, image_path_buffer);
	if (status < 0) {
		andock_image_result_release(&existing);
		return status;
	}
	if (remove_directory) {
		status = directory_empty(image_path_buffer);
		if (status <= 0) {
			andock_image_result_release(&existing);
			return status < 0 ? status : -ENOTEMPTY;
		}
	}
	int ext4_result = remove_directory ? ext4_dir_rm(image_path_buffer) :
		ext4_fremove(image_path_buffer);
	if (ext4_result != EOK) {
		andock_image_result_release(&existing);
		return -ext4_result;
	}
	invalidate_socket_reservations(resolved);
	if (cached != NULL && existing.links <= 1) {
		cached->unlinked = true;
		if (cached->references == 0)
			remove_cached_inode(cached);
	}
	andock_image_result_release(&existing);
	return result_path(result, resolved);
}

static int rename_operation(int flags, const char *source,
		const char *target, struct andock_image_result *result)
{
	if (flags != 0)
		return -EINVAL;
	char resolved_source[PATH_MAX];
	char resolved_target[PATH_MAX];
	char parent[PATH_MAX];
	int source_type;
	int status = resolve_guest(source, false, false,
		resolved_source, &source_type);
	if (status < 0)
		return status;
	status = resolve_parent(target, resolved_target, parent);
	if (status < 0)
		return status;
	struct andock_image_result source_metadata;
	struct andock_image_result target_metadata;
	result_init(&source_metadata);
	result_init(&target_metadata);
	status = metadata(resolved_source, source_type, &source_metadata);
	if (status < 0)
		return status;
	int target_type;
	bool target_exists = raw_type(resolved_target, &target_type) == 0;
	if (target_exists) {
		status = metadata(resolved_target, target_type, &target_metadata);
		if (status < 0) {
			andock_image_result_release(&source_metadata);
			return status;
		}
		if (source_metadata.inode != target_metadata.inode) {
			struct cached_inode *target_cached =
				find_cached_inode(target_metadata.inode);
			if (target_cached != NULL) {
				status = sync_cached_inode(target_cached);
				if (status < 0) {
					andock_image_result_release(&source_metadata);
					andock_image_result_release(&target_metadata);
					return status;
				}
			}
		}
	}
	char image_source[PATH_MAX];
	char image_target[PATH_MAX];
	status = mount_path(resolved_source, image_source);
	if (status == 0)
		status = mount_path(resolved_target, image_target);
	if (status < 0)
		return status;
	int ext4_result = source_type == ANDOCK_IMAGE_DIRECTORY ?
		ext4_dir_mv(image_source, image_target) :
		ext4_frename(image_source, image_target);
	if (ext4_result != EOK) {
		andock_image_result_release(&source_metadata);
		andock_image_result_release(&target_metadata);
		return -ext4_result;
	}
	rename_socket_reservations(resolved_source, resolved_target);
	if (target_exists && source_metadata.inode != target_metadata.inode &&
		target_metadata.links <= 1) {
		struct cached_inode *target_cached =
			find_cached_inode(target_metadata.inode);
		if (target_cached != NULL) {
			target_cached->unlinked = true;
			if (target_cached->references == 0)
				remove_cached_inode(target_cached);
		}
	}
	andock_image_result_release(&source_metadata);
	andock_image_result_release(&target_metadata);
	return result_path(result, resolved_target);
}

static int symlink_operation(const char *target, const char *link_path,
		struct andock_image_result *result)
{
	if (target == NULL || strlen(target) >= PATH_MAX)
		return -EINVAL;
	char resolved[PATH_MAX];
	char parent[PATH_MAX];
	int status = resolve_parent(link_path, resolved, parent);
	if (status < 0)
		return status;
	int type;
	if (raw_type(resolved, &type) == 0)
		return -EEXIST;
	char image_path_buffer[PATH_MAX];
	status = mount_path(resolved, image_path_buffer);
	if (status < 0)
		return status;
	int ext4_result = ext4_fsymlink(target, image_path_buffer);
	if (ext4_result != EOK)
		return -ext4_result;
	return metadata(resolved, ANDOCK_IMAGE_SYMLINK, result);
}

static int chmod_operation(int flags, mode_t mode, const char *path,
		struct andock_image_result *result)
{
	if ((flags & ~AT_SYMLINK_NOFOLLOW) != 0)
		return -EINVAL;
	char resolved[PATH_MAX];
	int type;
	int status = resolve_guest(path,
		(flags & AT_SYMLINK_NOFOLLOW) == 0, false, resolved, &type);
	if (status < 0)
		return status;
	if (type == ANDOCK_IMAGE_SYMLINK)
		return -EOPNOTSUPP;
	char image_path_buffer[PATH_MAX];
	status = mount_path(resolved, image_path_buffer);
	if (status < 0)
		return status;
	int ext4_result = ext4_mode_set(image_path_buffer, mode & 07777);
	if (ext4_result != EOK)
		return -ext4_result;
	status = metadata(resolved, type, result);
	if (status < 0)
		return status;
	return 0;
}

static int truncate_operation(const char *path, const void *data,
		size_t data_size, struct andock_image_result *result)
{
	if (data_size != sizeof(uint64_t))
		return -EINVAL;
	uint64_t encoded;
	memcpy(&encoded, data, sizeof(encoded));
	uint64_t length = be64_to_host(encoded);
	char resolved[PATH_MAX];
	int type;
	int status = resolve_guest(path, true, false, resolved, &type);
	if (status < 0)
		return status;
	if (type != ANDOCK_IMAGE_FILE)
		return -EISDIR;
	char image_path_buffer[PATH_MAX];
	status = mount_path(resolved, image_path_buffer);
	if (status < 0)
		return status;
	ext4_file file;
	memset(&file, 0, sizeof(file));
	int ext4_result = ext4_fopen2(&file, image_path_buffer, O_RDWR);
	if (ext4_result == EOK)
		ext4_result = ext4_ftruncate(&file, length);
	if (ext4_result == EOK)
		ext4_result = ext4_fclose(&file);
	else if (file.mp != NULL)
		ext4_fclose(&file);
	if (ext4_result != EOK)
		return -ext4_result;
	status = metadata(resolved, type, result);
	struct cached_inode *cached = status == 0 ?
		find_cached_inode(result->inode) : NULL;
	if (cached != NULL) {
		if (ftruncate(cached->memory_fd, (off_t)length) != 0)
			return -errno;
		cached->dirty = false;
	}
	return status;
}

static int statfs_operation(const char *path,
		struct andock_image_result *result)
{
	char resolved[PATH_MAX];
	int type;
	int status = resolve_guest(path, true, false, resolved, &type);
	if (status < 0)
		return status;
	struct ext4_mount_stats stats;
	memset(&stats, 0, sizeof(stats));
	int ext4_result = ext4_mount_point_stats(ANDOCK_IMAGE_MOUNT, &stats);
	if (ext4_result != EOK)
		return -ext4_result;
	uint64_t fields[8] = {
		host_to_be64(stats.block_size),
		host_to_be64(stats.blocks_count),
		host_to_be64(stats.free_blocks_count),
		host_to_be64(stats.free_blocks_count),
		host_to_be64(stats.inodes_count),
		host_to_be64(stats.free_inodes_count),
		host_to_be64(255),
		host_to_be64(0),
	};
	result->type = type;
	status = result_path(result, resolved);
	return status < 0 ? status : result_data(result, fields, sizeof(fields));
}

static int utimens_operation(int flags, const char *path, const void *data,
		size_t data_size, struct andock_image_result *result)
{
	if ((flags & ~AT_SYMLINK_NOFOLLOW) != 0 ||
		data_size != 4 * sizeof(uint64_t))
		return -EINVAL;
	uint64_t values[4];
	memcpy(values, data, sizeof(values));
	for (size_t index = 0; index < 4; ++index)
		values[index] = be64_to_host(values[index]);
	char resolved[PATH_MAX];
	int type;
	int status = resolve_guest(path,
		(flags & AT_SYMLINK_NOFOLLOW) == 0, false, resolved, &type);
	if (status < 0)
		return status;
	char image_path_buffer[PATH_MAX];
	status = mount_path(resolved, image_path_buffer);
	if (status < 0)
		return status;
	time_t now = time(NULL);
	const uint64_t utime_now = ((uint64_t)1 << 30) - 1;
	const uint64_t utime_omit = ((uint64_t)1 << 30) - 2;
	int ext4_result = EOK;
	if (values[1] != utime_omit) {
		uint32_t seconds = values[1] == utime_now ?
			(uint32_t)now : (uint32_t)values[0];
		ext4_result = ext4_atime_set(image_path_buffer, seconds);
	}
	if (ext4_result == EOK && values[3] != utime_omit) {
		uint32_t seconds = values[3] == utime_now ?
			(uint32_t)now : (uint32_t)values[2];
		ext4_result = ext4_mtime_set(image_path_buffer, seconds);
	}
	if (ext4_result != EOK)
		return -ext4_result;
	status = metadata(resolved, type, result);
	if (status < 0)
		return status;
	struct cached_inode *cached = find_cached_inode(result->inode);
	if (cached != NULL) {
		if (values[1] != utime_omit)
			cached->atime = values[1] == utime_now ? (int64_t)now
				: (int64_t)values[0];
		if (values[3] != utime_omit)
			cached->mtime = values[3] == utime_now ? (int64_t)now
				: (int64_t)values[2];
		cached->ctime = now;
		cached->timestamps_explicit = true;
		result->atime = cached->atime;
		result->mtime = cached->mtime;
		result->ctime = cached->ctime;
	}
	return 0;
}

static int link_operation(int flags, const char *source, const char *target,
		struct andock_image_result *result)
{
#ifndef AT_SYMLINK_FOLLOW
#define AT_SYMLINK_FOLLOW 0x400
#endif
	if ((flags & ~AT_SYMLINK_FOLLOW) != 0)
		return -EINVAL;
	char resolved_source[PATH_MAX];
	char resolved_target[PATH_MAX];
	char parent[PATH_MAX];
	int source_type;
	int status = resolve_guest(source,
		(flags & AT_SYMLINK_FOLLOW) != 0, false,
		resolved_source, &source_type);
	if (status < 0)
		return status;
	if (source_type == ANDOCK_IMAGE_DIRECTORY)
		return -EPERM;
	status = resolve_parent(target, resolved_target, parent);
	if (status < 0)
		return status;
	int target_type;
	if (raw_type(resolved_target, &target_type) == 0)
		return -EEXIST;
	char image_source[PATH_MAX];
	char image_target[PATH_MAX];
	status = mount_path(resolved_source, image_source);
	if (status == 0)
		status = mount_path(resolved_target, image_target);
	if (status < 0)
		return status;
	int ext4_result = ext4_flink(image_source, image_target);
	if (ext4_result != EOK)
		return -ext4_result;
	return metadata(resolved_target, source_type, result);
}

static bool allowed_xattr(const char *name)
{
	return name != NULL && strncmp(name, "user.", 5) == 0 &&
		strlen(name) < 256;
}

static int resolve_xattr_target(int flags, const char *path,
		char resolved[PATH_MAX], char image_path_buffer[PATH_MAX], int *type)
{
	if ((flags & ~(AT_SYMLINK_NOFOLLOW | XATTR_CREATE | XATTR_REPLACE)) != 0)
		return -EINVAL;
	int status = resolve_guest(path,
		(flags & AT_SYMLINK_NOFOLLOW) == 0, false, resolved, type);
	if (status < 0)
		return status;
	if ((flags & AT_SYMLINK_NOFOLLOW) != 0 &&
		*type == ANDOCK_IMAGE_SYMLINK)
		return -ENODATA;
	return mount_path(resolved, image_path_buffer);
}

static int list_xattr_operation(int flags, const char *path,
		struct andock_image_result *result)
{
	char resolved[PATH_MAX];
	char image_path_buffer[PATH_MAX];
	int type;
	int status = resolve_xattr_target(flags, path, resolved,
		image_path_buffer, &type);
	if (status < 0)
		return status;
	size_t size = 0;
	int ext4_result = ext4_listxattr(image_path_buffer, NULL, 0, &size);
	if (ext4_result != EOK && ext4_result != ERANGE)
		return -ext4_result;
	if (size > ANDOCK_IMAGE_MAX_XATTR_BYTES)
		return -E2BIG;
	uint8_t *data = size == 0 ? NULL : malloc(size);
	if (size != 0 && data == NULL)
		return -ENOMEM;
	if (size != 0) {
		ext4_result = ext4_listxattr(image_path_buffer,
			(char *)data, size, &size);
		if (ext4_result != EOK) {
			free(data);
			return -ext4_result;
		}
		size_t input = 0;
		size_t output = 0;
		while (input < size) {
			size_t remaining = size - input;
			size_t name_size = strnlen((char *)data + input, remaining);
			if (name_size == remaining) {
				free(data);
				return -EIO;
			}
			name_size++;
			if (allowed_xattr((char *)data + input)) {
				memmove(data + output, data + input, name_size);
				output += name_size;
			}
			input += name_size;
		}
		size = output;
	}
	result->type = type;
	result->data = data;
	result->data_size = size;
	return result_path(result, resolved);
}

static int get_xattr_operation(int flags, const char *path, const char *name,
		struct andock_image_result *result)
{
	if (!allowed_xattr(name))
		return -ENODATA;
	char resolved[PATH_MAX];
	char image_path_buffer[PATH_MAX];
	int type;
	int status = resolve_xattr_target(flags, path, resolved,
		image_path_buffer, &type);
	if (status < 0)
		return status;
	size_t size = 0;
	int ext4_result = ext4_getxattr(image_path_buffer, name, strlen(name),
		NULL, 0, &size);
	if (ext4_result != EOK && ext4_result != ERANGE)
		return -ext4_result;
	if (size > ANDOCK_IMAGE_MAX_XATTR_BYTES)
		return -E2BIG;
	uint8_t *data = size == 0 ? NULL : malloc(size);
	if (size != 0 && data == NULL)
		return -ENOMEM;
	if (size != 0) {
		ext4_result = ext4_getxattr(image_path_buffer, name, strlen(name),
			data, size, &size);
		if (ext4_result != EOK) {
			free(data);
			return -ext4_result;
		}
	}
	result->type = type;
	result->data = data;
	result->data_size = size;
	return result_path(result, resolved);
}

static int set_xattr_operation(int flags, const char *path, const char *name,
		const void *data, size_t data_size,
		struct andock_image_result *result)
{
	if (!allowed_xattr(name))
		return -EPERM;
	if (data_size > ANDOCK_IMAGE_MAX_XATTR_BYTES)
		return -E2BIG;
	int operation_flags = flags & (XATTR_CREATE | XATTR_REPLACE);
	if (operation_flags == (XATTR_CREATE | XATTR_REPLACE))
		return -EINVAL;
	char resolved[PATH_MAX];
	char image_path_buffer[PATH_MAX];
	int type;
	int status = resolve_xattr_target(flags, path, resolved,
		image_path_buffer, &type);
	if (status < 0)
		return status;
	uint8_t byte;
	size_t old_size = 0;
	bool exists = ext4_getxattr(image_path_buffer, name, strlen(name),
		&byte, sizeof(byte), &old_size) == EOK || old_size > 0;
	if ((operation_flags & XATTR_CREATE) != 0 && exists)
		return -EEXIST;
	if ((operation_flags & XATTR_REPLACE) != 0 && !exists)
		return -ENODATA;
	int ext4_result = ext4_setxattr(image_path_buffer, name, strlen(name),
		data, data_size);
	if (ext4_result != EOK)
		return -ext4_result;
	return metadata(resolved, type, result);
}

static int remove_xattr_operation(int flags, const char *path,
		const char *name, struct andock_image_result *result)
{
	if (!allowed_xattr(name))
		return -EPERM;
	char resolved[PATH_MAX];
	char image_path_buffer[PATH_MAX];
	int type;
	int status = resolve_xattr_target(flags, path, resolved,
		image_path_buffer, &type);
	if (status < 0)
		return status;
	int ext4_result = ext4_removexattr(image_path_buffer, name, strlen(name));
	if (ext4_result != EOK)
		return -ext4_result;
	return metadata(resolved, type, result);
}

static bool operation_may_allocate(int operation, int flags)
{
	switch (operation) {
	case ANDOCK_IMAGE_OPEN:
		return (flags & (O_CREAT | O_TRUNC)) != 0;
	case ANDOCK_IMAGE_MKDIR:
	case ANDOCK_IMAGE_SYMLINK_CREATE:
	case ANDOCK_IMAGE_SOCKET_CREATE:
	case ANDOCK_IMAGE_LINK:
	case ANDOCK_IMAGE_SET_XATTR:
		return true;
	default:
		return false;
	}
}

int andock_image_engine_call(int operation, int flags, mode_t mode,
		const char *path, const char *second_path,
		const void *data, size_t data_size,
		struct andock_image_result *result)
{
	if (member_image_fd < 0 || result == NULL)
		return -ENODEV;
	result_init(result);
	if (operation_may_allocate(operation, flags)) {
		int capacity = ensure_host_storage(ANDOCK_IMAGE_IO_BYTES);
		if (capacity < 0)
			return capacity;
	}
	latest_lookup.valid = false;
	reuse_latest_lookup = operation == ANDOCK_IMAGE_RESOLVE;
	if (operation != ANDOCK_IMAGE_RESOLVE)
		clear_directory_cache();
	int status;
	switch (operation) {
	case ANDOCK_IMAGE_RESOLVE:
		status = resolve_operation(flags, path, result);
		break;
	case ANDOCK_IMAGE_OPEN:
		status = open_operation(flags, mode, path, result);
		break;
	case ANDOCK_IMAGE_READLINK:
		status = readlink_operation(path, result);
		break;
	case ANDOCK_IMAGE_LIST:
		status = list_operation(path, result);
		break;
	case ANDOCK_IMAGE_MKDIR:
		status = mkdir_operation(mode, path, result);
		break;
	case ANDOCK_IMAGE_UNLINK:
		status = unlink_operation(flags, path, result);
		break;
	case ANDOCK_IMAGE_RENAME:
		status = rename_operation(flags, path, second_path, result);
		break;
	case ANDOCK_IMAGE_SYMLINK_CREATE:
		status = symlink_operation(second_path, path, result);
		break;
	case ANDOCK_IMAGE_CHMOD:
		status = chmod_operation(flags, mode, path, result);
		break;
	case ANDOCK_IMAGE_TRUNCATE:
		status = truncate_operation(path, data, data_size, result);
		break;
	case ANDOCK_IMAGE_SOCKET_CREATE:
		status = socket_operation(mode, path, result);
		break;
	case ANDOCK_IMAGE_STATFS:
		status = statfs_operation(path, result);
		break;
	case ANDOCK_IMAGE_UTIMENS:
		status = utimens_operation(flags, path, data, data_size, result);
		break;
	case ANDOCK_IMAGE_LINK:
		status = link_operation(flags, path, second_path, result);
		break;
	case ANDOCK_IMAGE_LIST_XATTR:
		status = list_xattr_operation(flags, path, result);
		break;
	case ANDOCK_IMAGE_GET_XATTR:
		status = get_xattr_operation(flags, path, second_path, result);
		break;
	case ANDOCK_IMAGE_SET_XATTR:
		status = set_xattr_operation(flags, path, second_path,
			data, data_size, result);
		break;
	case ANDOCK_IMAGE_REMOVE_XATTR:
		status = remove_xattr_operation(flags, path, second_path, result);
		break;
	case ANDOCK_IMAGE_SOCKET_CANCEL:
		status = socket_finish_operation(true, data, data_size, result);
		break;
	case ANDOCK_IMAGE_SOCKET_COMMIT:
		status = socket_finish_operation(false, data, data_size, result);
		break;
	default:
		status = -ENOSYS;
		break;
	}
	if (operation != ANDOCK_IMAGE_RESOLVE)
		clear_directory_cache();
	if (status < 0)
		andock_image_result_release(result);
	return status;
}
