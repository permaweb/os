#define _GNU_SOURCE
#define _FILE_OFFSET_BITS 64

#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdbool.h>
#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#include <ext4.h>
#include <ext4_blockdev.h>
#include <ext4_errno.h>
#include <ext4_mkfs.h>
#include <ext4_types.h>

#ifdef __ANDROID__
#include <jni.h>
#endif

#define IMAGE_BYTES (64ULL * 1024ULL * 1024ULL)
#define PHYSICAL_BLOCK_SIZE 512U
#define DEVICE_NAME "andock-image"
#define MOUNT_POINT "/image/"
#define REPORT_BYTES 16384U
#define CRASH_EXIT_CODE 86

struct report {
	char data[REPORT_BYTES];
	size_t used;
	bool ok;
};

static int active_fd = -1;

static int image_open(struct ext4_blockdev *bdev);
static int image_bread(struct ext4_blockdev *bdev, void *buffer,
		uint64_t block, uint32_t count);
static int image_bwrite(struct ext4_blockdev *bdev, const void *buffer,
		uint64_t block, uint32_t count);
static int image_close(struct ext4_blockdev *bdev);

EXT4_BLOCKDEV_STATIC_INSTANCE(
	image_device,
	PHYSICAL_BLOCK_SIZE,
	0,
	image_open,
	image_bread,
	image_bwrite,
	image_close,
	NULL,
	NULL
);

static void report_init(struct report *report)
{
	memset(report, 0, sizeof(*report));
	report->ok = true;
}

static void report_append(struct report *report, const char *format, ...)
{
	if (report->used >= sizeof(report->data) - 1)
		return;

	va_list args;
	va_start(args, format);
	int written = vsnprintf(
		report->data + report->used,
		sizeof(report->data) - report->used,
		format,
		args
	);
	va_end(args);
	if (written < 0)
		return;

	size_t remaining = sizeof(report->data) - report->used;
	report->used += (size_t)written < remaining ? (size_t)written : remaining - 1;
}

static void report_rc(struct report *report, const char *name, int result)
{
	if (result == EOK) {
		report_append(report, "%s=ok\n", name);
		return;
	}
	report->ok = false;
	report_append(report, "%s=error:%d\n", name, result);
}

static void report_bool(struct report *report, const char *name, bool value)
{
	if (!value)
		report->ok = false;
	report_append(report, "%s=%s\n", name, value ? "ok" : "failed");
}

static int exact_pread(int fd, void *buffer, size_t length, off_t offset)
{
	uint8_t *cursor = buffer;
	while (length > 0) {
		ssize_t count = pread(fd, cursor, length, offset);
		if (count < 0 && errno == EINTR)
			continue;
		if (count <= 0)
			return EIO;
		cursor += count;
		offset += count;
		length -= (size_t)count;
	}
	return EOK;
}

static int exact_pwrite(int fd, const void *buffer, size_t length, off_t offset)
{
	const uint8_t *cursor = buffer;
	while (length > 0) {
		ssize_t count = pwrite(fd, cursor, length, offset);
		if (count < 0 && errno == EINTR)
			continue;
		if (count <= 0)
			return EIO;
		cursor += count;
		offset += count;
		length -= (size_t)count;
	}
	return EOK;
}

static bool block_range(struct ext4_blockdev *bdev, uint64_t block,
		uint32_t count, off_t *offset, size_t *length)
{
	uint64_t block_size = bdev->bdif->ph_bsize;
	if (block > UINT64_MAX / block_size ||
		(uint64_t)count > UINT64_MAX / block_size)
		return false;

	uint64_t start = block * block_size;
	uint64_t bytes = (uint64_t)count * block_size;
	if (start > bdev->part_size || bytes > bdev->part_size - start ||
		start > (uint64_t)INT64_MAX || bytes > SIZE_MAX)
		return false;

	*offset = (off_t)(bdev->part_offset + start);
	*length = (size_t)bytes;
	return true;
}

static int image_open(struct ext4_blockdev *bdev)
{
	struct stat status;
	if (active_fd < 0 || fstat(active_fd, &status) != 0 ||
		status.st_size < (off_t)(2 * PHYSICAL_BLOCK_SIZE))
		return EIO;

	bdev->part_offset = 0;
	bdev->part_size = (uint64_t)status.st_size;
	bdev->bdif->ph_bcnt = bdev->part_size / bdev->bdif->ph_bsize;
	return EOK;
}

static int image_bread(struct ext4_blockdev *bdev, void *buffer,
		uint64_t block, uint32_t count)
{
	off_t offset;
	size_t length;
	if (!block_range(bdev, block, count, &offset, &length))
		return EIO;
	if (length == 0)
		return EOK;
	return exact_pread(active_fd, buffer, length, offset);
}

static int image_bwrite(struct ext4_blockdev *bdev, const void *buffer,
		uint64_t block, uint32_t count)
{
	off_t offset;
	size_t length;
	if (!block_range(bdev, block, count, &offset, &length))
		return EIO;
	if (length == 0)
		return EOK;
	return exact_pwrite(active_fd, buffer, length, offset);
}

static int image_close(struct ext4_blockdev *bdev)
{
	(void)bdev;
	return active_fd >= 0 && fsync(active_fd) != 0 ? EIO : EOK;
}

static void reset_device(int fd)
{
	active_fd = fd;
	image_device.part_offset = 0;
	image_device.part_size = 0;
	image_device.bc = NULL;
	image_device.lg_bsize = 0;
	image_device.lg_bcnt = 0;
	image_device.cache_write_back = 0;
	image_device.fs = NULL;
	image_device.journal = NULL;
	image_device.bdif->ph_bcnt = 0;
	image_device.bdif->ph_refctr = 0;
	image_device.bdif->bread_ctr = 0;
	image_device.bdif->bwrite_ctr = 0;
}

static int format_image(int fd)
{
	if (ftruncate(fd, (off_t)IMAGE_BYTES) != 0)
		return errno;
	reset_device(fd);

	struct ext4_fs filesystem;
	struct ext4_mkfs_info info = {
		.len = IMAGE_BYTES,
		.block_size = 4096,
		.journal = true,
		.label = "andock-probe",
	};
	memset(&filesystem, 0, sizeof(filesystem));
	int result = ext4_mkfs(&filesystem, &image_device, &info, F_SET_EXT4);
	if (result == EOK && fsync(fd) != 0)
		result = EIO;
	return result;
}

static int validate_mounted_image(int fd)
{
	struct ext4_mount_stats stats;
	struct stat status;
	memset(&stats, 0, sizeof(stats));
	int result = ext4_mount_point_stats(MOUNT_POINT, &stats);
	if (result != EOK)
		return result;
	if (fstat(fd, &status) != 0 || stats.block_size == 0 ||
		stats.blocks_count == 0 ||
		stats.blocks_count > (uint64_t)status.st_size / stats.block_size)
		return EINVAL;
	return EOK;
}

static int mount_image(int fd, bool recover)
{
	reset_device(fd);
	ext4_device_unregister_all();
	int result = ext4_device_register(&image_device, DEVICE_NAME);
	if (result != EOK)
		return result;

	result = ext4_mount(DEVICE_NAME, MOUNT_POINT, false);
	if (result != EOK) {
		ext4_device_unregister_all();
		return result;
	}
	result = validate_mounted_image(fd);
	if (result != EOK) {
		ext4_umount(MOUNT_POINT);
		ext4_device_unregister_all();
		return result;
	}
	if (recover) {
		result = ext4_recover(MOUNT_POINT);
		if (result != EOK) {
			ext4_umount(MOUNT_POINT);
			ext4_device_unregister_all();
			return result;
		}
	}
	result = ext4_journal_start(MOUNT_POINT);
	if (result != EOK) {
		ext4_umount(MOUNT_POINT);
		ext4_device_unregister_all();
	}
	return result;
}

static int unmount_image(void)
{
	int result = ext4_journal_stop(MOUNT_POINT);
	int unmount_result = ext4_umount(MOUNT_POINT);
	ext4_device_unregister_all();
	active_fd = -1;
	if (result != EOK)
		return result;
	return unmount_result;
}

static int write_file(const char *path, const void *data, size_t length)
{
	ext4_file file;
	int result = ext4_fopen(&file, path, "w+");
	if (result != EOK)
		return result;
	size_t written = 0;
	result = ext4_fwrite(&file, data, length, &written);
	int close_result = ext4_fclose(&file);
	if (result == EOK && written != length)
		result = EIO;
	return result != EOK ? result : close_result;
}

static int read_file(const char *path, char *buffer, size_t capacity,
		size_t *length)
{
	ext4_file file;
	int result = ext4_fopen(&file, path, "r");
	if (result != EOK)
		return result;
	size_t read = 0;
	result = ext4_fread(&file, buffer, capacity, &read);
	int close_result = ext4_fclose(&file);
	if (length)
		*length = read;
	return result != EOK ? result : close_result;
}

static bool directory_has(const char *path, const char *name)
{
	ext4_dir directory;
	if (ext4_dir_open(&directory, path) != EOK)
		return false;
	bool found = false;
	const ext4_direntry *entry;
	while ((entry = ext4_dir_entry_next(&directory)) != NULL) {
		if (strlen(name) == entry->name_length &&
			memcmp(entry->name, name, entry->name_length) == 0) {
			found = true;
			break;
		}
	}
	ext4_dir_close(&directory);
	return found;
}

static bool xattr_list_has(const char *list, size_t length, const char *name)
{
	size_t offset = 0;
	while (offset < length) {
		size_t remaining = length - offset;
		size_t entry_length = strnlen(list + offset, remaining);
		if (entry_length == remaining)
			return false;
		if (strcmp(list + offset, name) == 0)
			return true;
		offset += entry_length + 1;
	}
	return false;
}

struct tree_counts {
	uint64_t entries;
	uint64_t regular_files;
	uint64_t directories;
	uint64_t symlinks;
	uint64_t other;
};

static int inode_type_from_mode(const char *path)
{
	struct ext4_inode inode;
	if (ext4_raw_inode_fill(path, NULL, &inode) != EOK)
		return EXT4_DE_UNKNOWN;
	switch (inode.mode & EXT4_INODE_MODE_TYPE_MASK) {
	case EXT4_INODE_MODE_FILE:
		return EXT4_DE_REG_FILE;
	case EXT4_INODE_MODE_DIRECTORY:
		return EXT4_DE_DIR;
	case EXT4_INODE_MODE_SOFTLINK:
		return EXT4_DE_SYMLINK;
	default:
		return EXT4_DE_UNKNOWN;
	}
}

static int walk_tree(const char *path, struct tree_counts *counts)
{
	ext4_dir directory;
	int result = ext4_dir_open(&directory, path);
	if (result != EOK)
		return result;

	const ext4_direntry *entry;
	while ((entry = ext4_dir_entry_next(&directory)) != NULL) {
		if ((entry->name_length == 1 && entry->name[0] == '.') ||
			(entry->name_length == 2 && entry->name[0] == '.' &&
			entry->name[1] == '.'))
			continue;
		char child[4096];
		size_t path_length = strlen(path);
		bool separator = path_length > 0 && path[path_length - 1] != '/';
		if (path_length + (separator ? 1 : 0) + entry->name_length + 1 >
			sizeof(child)) {
			result = ENAMETOOLONG;
			break;
		}
		memcpy(child, path, path_length);
		size_t offset = path_length;
		if (separator)
			child[offset++] = '/';
		memcpy(child + offset, entry->name, entry->name_length);
		child[offset + entry->name_length] = 0;

		int type = entry->inode_type;
		if (type == EXT4_DE_UNKNOWN)
			type = inode_type_from_mode(child);
		counts->entries++;
		switch (type) {
		case EXT4_DE_REG_FILE:
			counts->regular_files++;
			break;
		case EXT4_DE_DIR:
			counts->directories++;
			result = walk_tree(child, counts);
			break;
		case EXT4_DE_SYMLINK:
			counts->symlinks++;
			break;
		default:
			counts->other++;
			break;
		}
		if (result != EOK)
			break;
	}
	int close_result = ext4_dir_close(&directory);
	return result != EOK ? result : close_result;
}

static int normalize_tree_owners(const char *path, uint64_t *updated)
{
	ext4_dir directory;
	int result = ext4_dir_open(&directory, path);
	if (result != EOK)
		return result;

	const ext4_direntry *entry;
	while ((entry = ext4_dir_entry_next(&directory)) != NULL) {
		if ((entry->name_length == 1 && entry->name[0] == '.') ||
			(entry->name_length == 2 && entry->name[0] == '.' &&
			entry->name[1] == '.'))
			continue;
		char child[4096];
		size_t path_length = strlen(path);
		bool separator = path_length > 0 && path[path_length - 1] != '/';
		if (path_length + (separator ? 1 : 0) + entry->name_length + 1 >
			sizeof(child)) {
			result = ENAMETOOLONG;
			break;
		}
		memcpy(child, path, path_length);
		size_t offset = path_length;
		if (separator)
			child[offset++] = '/';
		memcpy(child + offset, entry->name, entry->name_length);
		child[offset + entry->name_length] = 0;

		result = ext4_owner_set(child, 0, 0);
		if (result != EOK)
			break;
		(*updated)++;
		int type = entry->inode_type;
		if (type == EXT4_DE_UNKNOWN)
			type = inode_type_from_mode(child);
		if (type == EXT4_DE_DIR)
			result = normalize_tree_owners(child, updated);
		if (result != EOK)
			break;
	}
	int close_result = ext4_dir_close(&directory);
	return result != EOK ? result : close_result;
}

static void report_elf(struct report *report, const char *name,
		const char *path, uint64_t expected_size)
{
	char magic[4] = {0};
	size_t length = 0;
	int result = read_file(path, magic, sizeof(magic), &length);
	char result_name[96];
	snprintf(result_name, sizeof(result_name), "%s-read", name);
	report_rc(report, result_name, result);
	snprintf(result_name, sizeof(result_name), "%s-elf", name);
	report_bool(
		report,
		result_name,
		result == EOK && length == sizeof(magic) && magic[0] == 0x7f &&
		magic[1] == 'E' && magic[2] == 'L' && magic[3] == 'F'
	);
	ext4_file file;
	result = ext4_fopen(&file, path, "r");
	uint64_t size = result == EOK ? ext4_fsize(&file) : 0;
	if (result == EOK)
		ext4_fclose(&file);
	snprintf(result_name, sizeof(result_name), "%s-size", name);
	report_bool(report, result_name, size == expected_size);
}

static void report_symlink(struct report *report, const char *name,
		const char *path, const char *expected)
{
	char target[256] = {0};
	size_t length = 0;
	int result = ext4_readlink(path, target, sizeof(target), &length);
	char result_name[96];
	snprintf(result_name, sizeof(result_name), "%s-readlink", name);
	report_rc(report, result_name, result);
	snprintf(result_name, sizeof(result_name), "%s-target", name);
	report_bool(
		report,
		result_name,
		result == EOK && length == strlen(expected) &&
		memcmp(target, expected, length) == 0
	);
}

static void inspect_populated_root(struct report *report)
{
	struct tree_counts counts;
	memset(&counts, 0, sizeof(counts));
	int result = walk_tree(MOUNT_POINT, &counts);
	report_rc(report, "population-enumerate", result);
	report_append(report, "population-entries=%" PRIu64 "\n", counts.entries);
	report_append(report, "population-regular-files=%" PRIu64 "\n",
		counts.regular_files);
	report_append(report, "population-directories=%" PRIu64 "\n",
		counts.directories);
	report_append(report, "population-symlinks=%" PRIu64 "\n", counts.symlinks);
	report_append(report, "population-other=%" PRIu64 "\n", counts.other);
	report_bool(
		report,
		"population-counts",
		result == EOK && counts.entries == 26938 &&
		counts.regular_files == 22490 && counts.directories == 3485 &&
		counts.symlinks == 963 && counts.other == 0
	);

	report_elf(
		report,
		"population-glibc",
		MOUNT_POINT "usr/lib/aarch64-linux-gnu/libc.so.6",
		1722920
	);
	report_elf(
		report,
		"population-python",
		MOUNT_POINT "usr/bin/python3.12",
		7845048
	);
	report_elf(
		report,
		"population-node",
		MOUNT_POINT "usr/local/bin/node",
		122162360
	);
	report_symlink(report, "population-bin", MOUNT_POINT "bin", "usr/bin");
	report_symlink(report, "population-shell", MOUNT_POINT "usr/bin/sh", "dash");
	report_symlink(
		report,
		"population-python-link",
		MOUNT_POINT "usr/bin/python3",
		"python3.12"
	);
	report_symlink(report, "population-lib", MOUNT_POINT "lib", "usr/lib");
	report_symlink(
		report,
		"population-loader-link",
		MOUNT_POINT "usr/lib/ld-linux-aarch64.so.1",
		"aarch64-linux-gnu/ld-linux-aarch64.so.1"
	);
	report_symlink(
		report,
		"population-os-release-link",
		MOUNT_POINT "etc/os-release",
		"../usr/lib/os-release"
	);

	char os_release[4096] = {0};
	size_t length = 0;
	result = read_file(
		MOUNT_POINT "usr/lib/os-release",
		os_release,
		sizeof(os_release) - 1,
		&length
	);
	report_rc(report, "population-os-release-read", result);
	report_bool(
		report,
		"population-os-release",
		result == EOK && length > 0 && strstr(os_release, "Ubuntu") != NULL
	);

	uint32_t mode = 0;
	result = ext4_mode_get(MOUNT_POINT "usr/bin/passwd", &mode);
	report_rc(report, "population-setuid-mode-read", result);
	report_bool(
		report,
		"population-setuid-mode",
		result == EOK && (mode & 04755) == 04755
	);
	uint32_t uid = UINT32_MAX;
	uint32_t gid = UINT32_MAX;
	result = ext4_owner_get(MOUNT_POINT "usr/bin/passwd", &uid, &gid);
	report_rc(report, "population-owner-read", result);
	report_append(report, "population-passwd-uid=%" PRIu32 "\n", uid);
	report_append(report, "population-passwd-gid=%" PRIu32 "\n", gid);
	char xattrs[256] = {0};
	length = 0;
	result = ext4_listxattr(
		MOUNT_POINT "usr/bin/passwd",
		xattrs,
		sizeof(xattrs),
		&length
	);
	report_rc(report, "population-xattr-list", result);
	report_append(report, "population-xattr-bytes=%zu\n", length);
	report_bool(report, "population-source-xattrs-absent",
		result == EOK && length == 0);
}

static void create_fixture(struct report *report)
{
	static const char payload[] = "andock-image-engine-payload";
	report_rc(report, "directory-create", ext4_dir_mk(MOUNT_POINT "work"));
	report_rc(
		report,
		"file-create-write",
		write_file(MOUNT_POINT "work/alpha", payload, sizeof(payload) - 1)
	);

	char buffer[64] = {0};
	size_t length = 0;
	int result = read_file(MOUNT_POINT "work/alpha", buffer, sizeof(buffer), &length);
	report_rc(report, "file-read", result);
	report_bool(
		report,
		"file-read-content",
		result == EOK && length == sizeof(payload) - 1 &&
		memcmp(buffer, payload, sizeof(payload) - 1) == 0
	);

	ext4_file file;
	result = ext4_fopen(&file, MOUNT_POINT "work/alpha", "r+");
	report_rc(report, "file-open-truncate", result);
	if (result == EOK) {
		report_rc(report, "file-truncate", ext4_ftruncate(&file, 7));
		report_rc(report, "file-close-truncate", ext4_fclose(&file));
	}
	report_rc(
		report,
		"file-rename",
		ext4_frename(MOUNT_POINT "work/alpha", MOUNT_POINT "work/beta")
	);
	report_rc(
		report,
		"hard-link",
		ext4_flink(MOUNT_POINT "work/beta", MOUNT_POINT "work/beta.link")
	);
	report_rc(
		report,
		"symbolic-link",
		ext4_fsymlink("beta", MOUNT_POINT "work/beta.sym")
	);
	report_rc(report, "mode-set", ext4_mode_set(MOUNT_POINT "work/beta", 0751));
	report_rc(report, "atime-set", ext4_atime_set(MOUNT_POINT "work/beta", 1700000001));
	report_rc(report, "mtime-set", ext4_mtime_set(MOUNT_POINT "work/beta", 1700000002));
	report_rc(report, "ctime-set", ext4_ctime_set(MOUNT_POINT "work/beta", 1700000003));
	static const char xattr[] = "member-metadata";
	report_rc(
		report,
		"xattr-set",
		ext4_setxattr(
			MOUNT_POINT "work/beta",
			"user.andock",
			strlen("user.andock"),
			xattr,
			sizeof(xattr) - 1
		)
	);
	report_rc(report, "cache-flush", ext4_cache_flush(MOUNT_POINT));
	report_rc(
		report,
		"unlink-create",
		write_file(MOUNT_POINT "work/remove-me", "temporary", strlen("temporary"))
	);
	report_rc(report, "unlink", ext4_fremove(MOUNT_POINT "work/remove-me"));
	report_bool(
		report,
		"unlink-persisted",
		ext4_inode_exist(MOUNT_POINT "work/remove-me", EXT4_DE_REG_FILE) != EOK
	);
	report_bool(report, "directory-list-beta", directory_has(MOUNT_POINT "work", "beta"));
	report_bool(
		report,
		"directory-list-hard-link",
		directory_has(MOUNT_POINT "work", "beta.link")
	);
	report_bool(
		report,
		"directory-list-symlink",
		directory_has(MOUNT_POINT "work", "beta.sym")
	);
}

static void verify_fixture(struct report *report, bool require_crash_file)
{
	struct ext4_mount_stats stats;
	memset(&stats, 0, sizeof(stats));
	int result = ext4_mount_point_stats(MOUNT_POINT, &stats);
	report_rc(report, "superblock-open", result);
	report_bool(
		report,
		"superblock-shape",
		result == EOK && stats.block_size == 4096 && stats.blocks_count > 0 &&
		stats.inodes_count > 0
	);

	char buffer[64] = {0};
	size_t length = 0;
	result = read_file(MOUNT_POINT "work/beta", buffer, sizeof(buffer), &length);
	report_rc(report, "reopen-read", result);
	report_bool(
		report,
		"truncate-persisted",
		result == EOK && length == 7 && memcmp(buffer, "andock-", 7) == 0
	);

	uint32_t beta_inode = 0;
	uint32_t link_inode = 0;
	struct ext4_inode inode;
	report_rc(
		report,
		"hard-link-inode",
		ext4_raw_inode_fill(MOUNT_POINT "work/beta", &beta_inode, &inode)
	);
	report_rc(
		report,
		"hard-link-target-inode",
		ext4_raw_inode_fill(MOUNT_POINT "work/beta.link", &link_inode, &inode)
	);
	report_bool(report, "hard-link-persisted", beta_inode != 0 && beta_inode == link_inode);

	char link[32] = {0};
	length = 0;
	result = ext4_readlink(MOUNT_POINT "work/beta.sym", link, sizeof(link), &length);
	report_rc(report, "symlink-read", result);
	report_bool(
		report,
		"symlink-persisted",
		result == EOK && length == 4 && memcmp(link, "beta", 4) == 0
	);

	uint32_t value = 0;
	result = ext4_mode_get(MOUNT_POINT "work/beta", &value);
	report_rc(report, "mode-get", result);
	report_bool(report, "mode-persisted", result == EOK && (value & 0777) == 0751);
	result = ext4_atime_get(MOUNT_POINT "work/beta", &value);
	report_rc(report, "atime-get", result);
	report_bool(report, "atime-persisted", result == EOK && value == 1700000001);
	result = ext4_mtime_get(MOUNT_POINT "work/beta", &value);
	report_rc(report, "mtime-get", result);
	report_bool(report, "mtime-persisted", result == EOK && value == 1700000002);
	result = ext4_ctime_get(MOUNT_POINT "work/beta", &value);
	report_rc(report, "ctime-get", result);
	report_bool(report, "ctime-persisted", result == EOK && value == 1700000003);

	char xattr[32] = {0};
	length = 0;
	result = ext4_getxattr(
		MOUNT_POINT "work/beta",
		"user.andock",
		strlen("user.andock"),
		xattr,
		sizeof(xattr),
		&length
	);
	report_rc(report, "xattr-get", result);
	report_bool(
		report,
		"xattr-persisted",
		result == EOK && length == strlen("member-metadata") &&
		memcmp(xattr, "member-metadata", length) == 0
	);
	char xattr_list[128] = {0};
	length = 0;
	result = ext4_listxattr(
		MOUNT_POINT "work/beta",
		xattr_list,
		sizeof(xattr_list),
		&length
	);
	report_rc(report, "xattr-list", result);
	report_bool(
		report,
		"xattr-list-persisted",
		result == EOK && xattr_list_has(xattr_list, length, "user.andock")
	);

	report_bool(report, "directory-enumeration", directory_has(MOUNT_POINT "work", "beta"));
	if (require_crash_file) {
		memset(buffer, 0, sizeof(buffer));
		length = 0;
		result = read_file(MOUNT_POINT "work/crash.dat", buffer, sizeof(buffer), &length);
		report_rc(report, "crash-recovery-read", result);
		report_bool(
			report,
			"crash-recovery-content",
			result == EOK && length == strlen("committed-before-crash") &&
			memcmp(buffer, "committed-before-crash", length) == 0
		);
	}
}

static void finish_report(struct report *report, int fd)
{
	struct stat status;
	report_append(report, "engine=lwext4\n");
	if (fd >= 0 && fstat(fd, &status) == 0)
		report_append(report, "image-bytes=%" PRIu64 "\n",
			(uint64_t)status.st_size);
	report_append(report, "result=%s\n", report->ok ? "ok" : "failed");
}

static void initialize_probe(int fd, struct report *report)
{
	report_init(report);
	report_rc(report, "format", format_image(fd));
	if (!report->ok) {
		finish_report(report, fd);
		return;
	}
	int result = mount_image(fd, true);
	report_rc(report, "mount", result);
	if (result == EOK) {
		create_fixture(report);
		report_rc(report, "unmount", unmount_image());
	}
	result = mount_image(fd, true);
	report_rc(report, "reopen", result);
	if (result == EOK) {
		verify_fixture(report, false);
		report_rc(report, "reopen-unmount", unmount_image());
	}
	finish_report(report, fd);
}

static void verify_probe(int fd, struct report *report)
{
	report_init(report);
	int result = mount_image(fd, true);
	report_rc(report, "recovery-mount", result);
	if (result == EOK) {
		verify_fixture(report, true);
		report_rc(report, "recovery-unmount", unmount_image());
	}
	finish_report(report, fd);
}

static void inspect_populated_probe(int fd, struct report *report)
{
	report_init(report);
	int result = mount_image(fd, true);
	report_rc(report, "population-mount", result);
	if (result == EOK) {
		inspect_populated_root(report);
		report_rc(report, "population-unmount", unmount_image());
	}
	finish_report(report, fd);
}

static void initialize_populated_probe(int fd, struct report *report)
{
	report_init(report);
	int result = mount_image(fd, true);
	report_rc(report, "population-mount", result);
	if (result == EOK) {
		inspect_populated_root(report);
		if (report->ok)
			create_fixture(report);
		report_rc(report, "population-mutation-unmount", unmount_image());
	}
	if (report->ok) {
		result = mount_image(fd, true);
		report_rc(report, "population-reopen", result);
		if (result == EOK) {
			verify_fixture(report, false);
			report_rc(report, "population-reopen-unmount", unmount_image());
		}
	}
	finish_report(report, fd);
}

static void normalize_populated_owners_probe(int fd, struct report *report)
{
	report_init(report);
	int result = mount_image(fd, true);
	report_rc(report, "owner-normalization-mount", result);
	uint64_t updated = 0;
	if (result == EOK) {
		result = ext4_owner_set(MOUNT_POINT, 0, 0);
		if (result == EOK) {
			updated++;
			result = normalize_tree_owners(MOUNT_POINT, &updated);
		}
		report_rc(report, "owner-normalization", result);
		report_append(report, "owner-normalization-inodes=%" PRIu64 "\n", updated);
		if (result == EOK)
			report_rc(report, "owner-normalization-flush",
				ext4_cache_flush(MOUNT_POINT));
		report_rc(report, "owner-normalization-unmount", unmount_image());
	}
	if (report->ok) {
		result = mount_image(fd, true);
		report_rc(report, "owner-normalization-reopen", result);
		if (result == EOK) {
			uint32_t uid = UINT32_MAX;
			uint32_t gid = UINT32_MAX;
			result = ext4_owner_get(MOUNT_POINT "usr/bin/passwd", &uid, &gid);
			report_rc(report, "owner-normalization-read", result);
			report_bool(report, "owner-normalization-root",
				result == EOK && uid == 0 && gid == 0);
			report_rc(report, "owner-normalization-reopen-unmount",
				unmount_image());
		}
	}
	finish_report(report, fd);
}

static void crash_after_mutation(int fd)
{
	if (mount_image(fd, true) != EOK)
		_exit(87);
	static const char payload[] = "committed-before-crash";
	if (write_file(
		MOUNT_POINT "work/crash.tmp",
		payload,
		sizeof(payload) - 1
	) != EOK)
		_exit(88);
	if (ext4_frename(
		MOUNT_POINT "work/crash.tmp",
		MOUNT_POINT "work/crash.dat"
	) != EOK)
		_exit(89);
	if (ext4_cache_flush(MOUNT_POINT) != EOK || fsync(fd) != 0)
		_exit(90);
	_exit(CRASH_EXIT_CODE);
}

static int raw_mount_result(int fd)
{
	reset_device(fd);
	ext4_device_unregister_all();
	int result = ext4_device_register(&image_device, DEVICE_NAME);
	if (result == EOK)
		result = ext4_mount(DEVICE_NAME, MOUNT_POINT, false);
	if (result == EOK) {
		result = validate_mounted_image(fd);
		ext4_umount(MOUNT_POINT);
	}
	ext4_device_unregister_all();
	active_fd = -1;
	return result;
}

static void malformed_probe(int fd, int kind, struct report *report)
{
	report_init(report);
	int prepare_result = EOK;
	const char *name = "unknown";
	if (kind == 0) {
		name = "zero-superblock";
		if (ftruncate(fd, 4 * 1024 * 1024) != 0)
			prepare_result = errno;
	} else {
		prepare_result = format_image(fd);
		if (prepare_result == EOK && kind == 1) {
			name = "bad-magic";
			const uint16_t bad_magic = 0;
			prepare_result = exact_pwrite(
				fd,
				&bad_magic,
				sizeof(bad_magic),
				EXT4_SUPERBLOCK_OFFSET + offsetof(struct ext4_sblock, magic)
			);
		} else if (prepare_result == EOK && kind == 2) {
			name = "truncated-image";
			if (ftruncate(fd, 2048) != 0)
				prepare_result = errno;
		} else if (prepare_result == EOK && kind == 3) {
			name = "unsupported-incompat-feature";
			const uint32_t unsupported = UINT32_C(0x80000000);
			prepare_result = exact_pwrite(
				fd,
				&unsupported,
				sizeof(unsupported),
				EXT4_SUPERBLOCK_OFFSET +
					offsetof(struct ext4_sblock, features_incompatible)
			);
		} else if (kind < 1 || kind > 3) {
			name = "invalid-probe-kind";
			prepare_result = EINVAL;
		}
	}
	if (prepare_result == EOK && fsync(fd) != 0)
		prepare_result = EIO;
	report_rc(report, "malformed-prepare", prepare_result);
	if (prepare_result == EOK) {
		int result = raw_mount_result(fd);
		report_append(report, "malformed-kind=%s\n", name);
		report_append(report, "malformed-mount-error=%d\n", result);
		report_bool(report, "malformed-rejected", result != EOK);
	}
	finish_report(report, fd);
}

static int copy_bytes(int source, int destination, off_t begin, off_t end)
{
	uint8_t *buffer = malloc(1024 * 1024);
	if (!buffer)
		return ENOMEM;
	int result = EOK;
	while (begin < end) {
		size_t length = (uint64_t)(end - begin) > 1024 * 1024
			? 1024 * 1024
			: (size_t)(end - begin);
		result = exact_pread(source, buffer, length, begin);
		if (result != EOK)
			break;
		result = exact_pwrite(destination, buffer, length, begin);
		if (result != EOK)
			break;
		begin += (off_t)length;
	}
	free(buffer);
	return result;
}

static bool zero_block(const uint8_t *buffer, size_t length)
{
	for (size_t index = 0; index < length; ++index) {
		if (buffer[index] != 0)
			return false;
	}
	return true;
}

static int sparse_copy_by_zero_scan(int source, int destination, off_t size)
{
	uint8_t buffer[4096];
	for (off_t offset = 0; offset < size; offset += (off_t)sizeof(buffer)) {
		size_t length = size - offset > (off_t)sizeof(buffer)
			? sizeof(buffer)
			: (size_t)(size - offset);
		int result = exact_pread(source, buffer, length, offset);
		if (result != EOK)
			return result;
		if (!zero_block(buffer, length)) {
			result = exact_pwrite(destination, buffer, length, offset);
			if (result != EOK)
				return result;
		}
	}
	return EOK;
}

static int sparse_copy_fd(int source, int destination, const char **mode)
{
	struct stat status;
	if (fstat(source, &status) != 0 || status.st_size < 0)
		return EIO;
	if (ftruncate(destination, status.st_size) != 0)
		return errno;

#if defined(SEEK_DATA) && defined(SEEK_HOLE)
	off_t offset = 0;
	bool unsupported = false;
	while (offset < status.st_size) {
		errno = 0;
		off_t data = lseek(source, offset, SEEK_DATA);
		if (data < 0 && errno == ENXIO)
			break;
		if (data < 0) {
			unsupported = errno == EINVAL || errno == ENOTSUP || errno == ENOSYS;
			if (!unsupported)
				return errno;
			break;
		}
		off_t hole = lseek(source, data, SEEK_HOLE);
		if (hole < 0) {
			unsupported = errno == EINVAL || errno == ENOTSUP || errno == ENOSYS;
			if (!unsupported)
				return errno;
			break;
		}
		if (hole > status.st_size)
			hole = status.st_size;
		int result = copy_bytes(source, destination, data, hole);
		if (result != EOK)
			return result;
		offset = hole;
	}
	if (!unsupported) {
		*mode = "seek-data-hole";
		return fsync(destination) == 0 ? EOK : EIO;
	}
	if (ftruncate(destination, 0) != 0 ||
		ftruncate(destination, status.st_size) != 0)
		return errno;
#endif

	*mode = "zero-scan";
	int result = sparse_copy_by_zero_scan(source, destination, status.st_size);
	if (result == EOK && fsync(destination) != 0)
		result = EIO;
	return result;
}

static void sparse_copy_probe(int source, int destination, struct report *report)
{
	report_init(report);
	struct timespec begin;
	struct timespec end;
	clock_gettime(CLOCK_MONOTONIC, &begin);
	const char *mode = "unavailable";
	int result = sparse_copy_fd(source, destination, &mode);
	clock_gettime(CLOCK_MONOTONIC, &end);
	report_rc(report, "sparse-copy", result);
	struct stat status;
	if (result == EOK && fstat(destination, &status) == 0) {
		int64_t elapsed =
			(int64_t)(end.tv_sec - begin.tv_sec) * INT64_C(1000000000) +
			(int64_t)end.tv_nsec - (int64_t)begin.tv_nsec;
		uint64_t elapsed_ns = elapsed > 0 ? (uint64_t)elapsed : 0;
		report_append(report, "sparse-copy-mode=%s\n", mode);
		report_append(report, "sparse-copy-nanoseconds=%" PRIu64 "\n", elapsed_ns);
		report_append(report, "sparse-copy-logical-bytes=%" PRIu64 "\n",
			(uint64_t)status.st_size);
		report_append(report, "sparse-copy-allocated-bytes=%" PRIu64 "\n",
			(uint64_t)status.st_blocks * 512);
	} else if (result == EOK) {
		report_bool(report, "sparse-copy-stat", false);
	}
	finish_report(report, destination);
}

#ifdef __ANDROID__
static jstring report_string(JNIEnv *env, const struct report *report)
{
	return (*env)->NewStringUTF(env, report->data);
}

JNIEXPORT jstring JNICALL
Java_org_permaweb_andee_imageprobe_NativeProbe_initialize(
	JNIEnv *env, jclass type, jint fd)
{
	(void)type;
	struct report report;
	initialize_probe(fd, &report);
	return report_string(env, &report);
}

JNIEXPORT jstring JNICALL
Java_org_permaweb_andee_imageprobe_NativeProbe_verify(
	JNIEnv *env, jclass type, jint fd)
{
	(void)type;
	struct report report;
	verify_probe(fd, &report);
	return report_string(env, &report);
}

JNIEXPORT void JNICALL
Java_org_permaweb_andee_imageprobe_NativeProbe_crashAfterMutation(
	JNIEnv *env, jclass type, jint fd)
{
	(void)env;
	(void)type;
	crash_after_mutation(fd);
}

JNIEXPORT jstring JNICALL
Java_org_permaweb_andee_imageprobe_NativeProbe_rejectMalformed(
	JNIEnv *env, jclass type, jint fd, jint kind)
{
	(void)type;
	struct report report;
	malformed_probe(fd, kind, &report);
	return report_string(env, &report);
}

JNIEXPORT jstring JNICALL
Java_org_permaweb_andee_imageprobe_NativeProbe_sparseCopy(
	JNIEnv *env, jclass type, jint source, jint destination)
{
	(void)type;
	struct report report;
	sparse_copy_probe(source, destination, &report);
	return report_string(env, &report);
}
#else
#include <sys/wait.h>

static int open_image(const char *path, bool truncate_image)
{
	int flags = O_RDWR | O_CREAT;
	if (truncate_image)
		flags |= O_TRUNC;
	return open(path, flags, 0600);
}

static int open_existing_image(const char *path)
{
	return open(path, O_RDWR);
}

static int wait_for_expected_crash(pid_t child)
{
	int status = 0;
	if (waitpid(child, &status, 0) != child || !WIFEXITED(status) ||
		WEXITSTATUS(status) != CRASH_EXIT_CODE) {
		fprintf(stderr, "crash child status=%d\n", status);
		return 1;
	}
	printf("crash-process-exit=%d\n", WEXITSTATUS(status));
	return 0;
}

static int run_host_probe(const char *path)
{
	int fd = open_image(path, true);
	if (fd < 0) {
		perror("open image");
		return 1;
	}
	struct report report;
	initialize_probe(fd, &report);
	fputs(report.data, stdout);
	if (!report.ok) {
		close(fd);
		return 1;
	}
	close(fd);

	pid_t child = fork();
	if (child < 0) {
		perror("fork");
		return 1;
	}
	if (child == 0) {
		fd = open_image(path, false);
		if (fd < 0)
			_exit(91);
		crash_after_mutation(fd);
	}
	if (wait_for_expected_crash(child) != 0)
		return 1;

	fd = open_image(path, false);
	if (fd < 0) {
		perror("reopen image");
		return 1;
	}
	verify_probe(fd, &report);
	fputs(report.data, stdout);
	close(fd);
	if (!report.ok)
		return 1;

	char copy_path[1024];
	if (snprintf(copy_path, sizeof(copy_path), "%s.copy", path) >=
		(int)sizeof(copy_path))
		return 1;
	int source = open_image(path, false);
	int destination = open_image(copy_path, true);
	if (source < 0 || destination < 0) {
		perror("open sparse copy");
		return 1;
	}
	sparse_copy_probe(source, destination, &report);
	fputs(report.data, stdout);
	close(source);
	close(destination);
	if (!report.ok)
		return 1;
	destination = open_image(copy_path, false);
	if (destination < 0) {
		perror("reopen sparse copy");
		return 1;
	}
	verify_probe(destination, &report);
	fputs(report.data, stdout);
	close(destination);
	if (!report.ok)
		return 1;

	for (int kind = 0; kind < 4; ++kind) {
		char malformed_path[1024];
		if (snprintf(
			malformed_path,
			sizeof(malformed_path),
			"%s.malformed-%d",
			path,
			kind
		) >= (int)sizeof(malformed_path))
			return 1;
		fd = open_image(malformed_path, true);
		if (fd < 0) {
			perror("open malformed image");
			return 1;
		}
		malformed_probe(fd, kind, &report);
		fputs(report.data, stdout);
		close(fd);
		if (!report.ok)
			return 1;
	}
	puts("host-native-probe=ok");
	return 0;
}

static int inspect_host_populated(const char *path)
{
	int fd = open_existing_image(path);
	if (fd < 0) {
		perror("open populated image");
		return 1;
	}
	struct report report;
	inspect_populated_probe(fd, &report);
	fputs(report.data, stdout);
	close(fd);
	return report.ok ? 0 : 1;
}

static int verify_host_populated(const char *path)
{
	int fd = open_existing_image(path);
	if (fd < 0) {
		perror("open populated image");
		return 1;
	}
	struct report report;
	initialize_populated_probe(fd, &report);
	fputs(report.data, stdout);
	close(fd);
	if (!report.ok)
		return 1;

	pid_t child = fork();
	if (child < 0) {
		perror("fork");
		return 1;
	}
	if (child == 0) {
		fd = open_existing_image(path);
		if (fd < 0)
			_exit(91);
		crash_after_mutation(fd);
	}
	if (wait_for_expected_crash(child) != 0)
		return 1;

	fd = open_existing_image(path);
	if (fd < 0) {
		perror("reopen populated image");
		return 1;
	}
	verify_probe(fd, &report);
	fputs(report.data, stdout);
	close(fd);
	if (!report.ok)
		return 1;
	puts("host-populated-probe=ok");
	return 0;
}

static int normalize_host_populated_owners(const char *path)
{
	int fd = open_existing_image(path);
	if (fd < 0) {
		perror("open populated image");
		return 1;
	}
	struct report report;
	normalize_populated_owners_probe(fd, &report);
	fputs(report.data, stdout);
	close(fd);
	return report.ok ? 0 : 1;
}

static int sparse_copy_host(const char *source_path, const char *destination_path)
{
	int source = open_existing_image(source_path);
	if (source < 0) {
		perror("open sparse copy");
		return 1;
	}
	int destination = open_image(destination_path, true);
	if (destination < 0) {
		perror("open sparse copy");
		close(source);
		return 1;
	}
	struct report report;
	sparse_copy_probe(source, destination, &report);
	fputs(report.data, stdout);
	close(source);
	close(destination);
	return report.ok ? 0 : 1;
}

int main(int argc, char **argv)
{
	if (argc == 2)
		return run_host_probe(argv[1]);
	if (argc == 3 && strcmp(argv[1], "--inspect-populated") == 0)
		return inspect_host_populated(argv[2]);
	if (argc == 3 && strcmp(argv[1], "--verify-populated") == 0)
		return verify_host_populated(argv[2]);
	if (argc == 3 && strcmp(argv[1], "--normalize-populated-owners") == 0)
		return normalize_host_populated_owners(argv[2]);
	if (argc == 4 && strcmp(argv[1], "--sparse-copy") == 0)
		return sparse_copy_host(argv[2], argv[3]);
	fprintf(
		stderr,
		"usage: %s IMAGE | --inspect-populated IMAGE | "
		"--verify-populated IMAGE | --normalize-populated-owners IMAGE | "
		"--sparse-copy SOURCE DESTINATION\n",
		argv[0]
	);
	return 2;
}
#endif
