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
#include <sys/syscall.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#include <ext4.h>
#include <ext4_blockdev.h>
#include <ext4_errno.h>
#include <ext4_inode.h>
#include <ext4_types.h>

#include "extension/andock_image/andock_image_engine.h"

#define ANDOCK_IMAGE_BLOCK_SIZE 512U
#define ANDOCK_IMAGE_DEVICE "andock-member-image"
#define ANDOCK_IMAGE_MOUNT "/andock/"
#define ANDOCK_IMAGE_MAX_SYMLINKS 40
#define ANDOCK_IMAGE_IO_BYTES (1024U * 1024U)
#define ANDOCK_IMAGE_MAX_XATTR_BYTES (1024U * 1024U)

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

struct cached_inode {
	uint64_t inode;
	uint64_t cache_id;
	int memory_fd;
	unsigned int references;
	bool dirty;
	bool unlinked;
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

static void remove_cached_inode(struct cached_inode *cached)
{
	struct cached_inode **cursor = &inode_cache;
	while (*cursor != NULL) {
		if (*cursor == cached) {
			*cursor = cached->next;
			close(cached->memory_fd);
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

static int raw_type(const char *guest, int *type)
{
	char path[PATH_MAX];
	int status = mount_path(guest, path);
	if (status < 0)
		return status;
	if (ext4_inode_exist(path, EXT4_DE_SYMLINK) == EOK)
		*type = ANDOCK_IMAGE_SYMLINK;
	else if (ext4_inode_exist(path, EXT4_DE_DIR) == EOK)
		*type = ANDOCK_IMAGE_DIRECTORY;
	else if (ext4_inode_exist(path, EXT4_DE_REG_FILE) == EOK)
		*type = ANDOCK_IMAGE_FILE;
	else {
		struct ext4_inode inode;
		if (ext4_raw_inode_fill(path, NULL, &inode) != EOK)
			return -ENOENT;
		uint32_t mode = 0;
		if (ext4_mode_get(path, &mode) != EOK)
			return -EIO;
		*type = (mode & S_IFMT) == S_IFSOCK
			? ANDOCK_IMAGE_SOCKET : ANDOCK_IMAGE_OTHER;
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
	char path[PATH_MAX];
	int status = mount_path(guest, path);
	if (status < 0)
		return status;

	uint32_t mode = 0;
	int ext4_result = ext4_mode_get(path, &mode);
	if (ext4_result != EOK)
		return -ext4_result;
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

	struct ext4_inode inode;
	uint32_t inode_number = 0;
	ext4_result = ext4_raw_inode_fill(path, &inode_number, &inode);
	if (ext4_result != EOK)
		return -ext4_result;
	result->inode = inode_number;
	result->links = ext4_inode_get_links_cnt(&inode);
	if (type == ANDOCK_IMAGE_FILE) {
		ext4_file file;
		ext4_result = ext4_fopen(&file, path, "r");
		if (ext4_result != EOK)
			return -ext4_result;
		result->size = ext4_fsize(&file);
		ext4_fclose(&file);
	} else if (type == ANDOCK_IMAGE_SYMLINK) {
		char link[PATH_MAX];
		size_t length = 0;
		ext4_result = ext4_readlink(path, link, sizeof(link), &length);
		if (ext4_result != EOK)
			return -ext4_result;
		result->size = length;
	}
	return result_path(result, guest);
}

static int reopen_memfd(int fd, int flags)
{
	(void)flags;
	int duplicate = fcntl(fd, F_DUPFD_CLOEXEC, 0);
	return duplicate < 0 ? -errno : duplicate;
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
	off_t offset = 0;
	while ((uint64_t)offset < size) {
		size_t wanted = size - (uint64_t)offset > ANDOCK_IMAGE_IO_BYTES ?
			ANDOCK_IMAGE_IO_BYTES : (size_t)(size - (uint64_t)offset);
		size_t read = 0;
		ext4_result = ext4_fread(&file, buffer, wanted, &read);
		if (ext4_result != EOK || read != wanted) {
			status = ext4_result == EOK ? -EIO : -ext4_result;
			dprintf(STDERR_FILENO,
				"andock: materialize %s: ext4 read failed: %s (%d)\n",
				guest, strerror(-status), status);
			break;
		}
		if (exact_pwrite(memory_fd, buffer, read, offset) != EOK) {
			status = -EIO;
			dprintf(STDERR_FILENO,
				"andock: materialize %s: memfd write failed: %s (%d)\n",
				guest, strerror(-status), status);
			break;
		}
		offset += (off_t)read;
	}
	free(buffer);
	ext4_fclose(&file);
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
	int guest_fd = reopen_memfd(cached->memory_fd, flags);
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
	if (type == ANDOCK_IMAGE_FILE)
		status = materialize(resolved, O_RDONLY | O_CLOEXEC, false, result);
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
	ext4_file file;
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
	ext4_result = ext4_ftruncate(&file, (uint64_t)status.st_size);
	if (ext4_result != EOK) {
		ext4_fclose(&file);
		return -ext4_result;
	}
	ext4_fseek(&file, 0, SEEK_SET);
	uint8_t *buffer = malloc(ANDOCK_IMAGE_IO_BYTES);
	if (buffer == NULL) {
		ext4_fclose(&file);
		return -ENOMEM;
	}
	off_t offset = 0;
	while (offset < status.st_size) {
		size_t wanted = status.st_size - offset > ANDOCK_IMAGE_IO_BYTES ?
			ANDOCK_IMAGE_IO_BYTES : (size_t)(status.st_size - offset);
		if (exact_pread(cached->memory_fd, buffer, wanted, offset) != EOK) {
			result = -EIO;
			break;
		}
		size_t written = 0;
		ext4_result = ext4_fwrite(&file, buffer, wanted, &written);
		if (ext4_result != EOK || written != wanted) {
			result = ext4_result == EOK ? -EIO : -ext4_result;
			break;
		}
		offset += (off_t)written;
	}
	free(buffer);
	ext4_fclose(&file);
	if (result == 0)
		result = andock_image_engine_flush();
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
	cached->dirty = true;
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

int andock_image_engine_sync(uint64_t cache_id)
{
	return sync_cached_inode(find_cached_id(cache_id));
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
	if (status == 0 && cached->unlinked)
		remove_cached_inode(cached);
	return status;
}

int andock_image_engine_sync_all(void)
{
	int first_error = 0;
	struct cached_inode *cached = inode_cache;
	while (cached != NULL) {
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

static int chmod_operation(mode_t mode, const char *path,
		struct andock_image_result *result)
{
	char resolved[PATH_MAX];
	int type;
	int status = resolve_guest(path, true, false, resolved, &type);
	if (status < 0)
		return status;
	char image_path_buffer[PATH_MAX];
	status = mount_path(resolved, image_path_buffer);
	if (status < 0)
		return status;
	int ext4_result = ext4_mode_set(image_path_buffer, mode & 07777);
	if (ext4_result != EOK)
		return -ext4_result;
	return metadata(resolved, type, result);
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
	return metadata(resolved, type, result);
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

int andock_image_engine_call(int operation, int flags, mode_t mode,
		const char *path, const char *second_path,
		const void *data, size_t data_size,
		struct andock_image_result *result)
{
	if (member_image_fd < 0 || result == NULL)
		return -ENODEV;
	result_init(result);
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
		status = chmod_operation(mode, path, result);
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
	if (status < 0)
		andock_image_result_release(result);
	return status;
}
