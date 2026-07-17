#include <arpa/inet.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <sched.h>
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <sys/uio.h>
#include <sys/vfs.h>
#include <sys/xattr.h>
#include <time.h>
#include <unistd.h>

#include <talloc.h>

#include "compat.h"
#include "extension/andock_image/andock_image.h"
#include "extension/andock_image/andock_image_engine.h"
#include "path/path.h"
#include "syscall/chain.h"
#include "syscall/socket.h"
#include "syscall/syscall.h"
#include "syscall/sysnum.h"
#include "tracee/mem.h"
#include "tracee/reg.h"
#include "tracee/statx.h"

#define ANDOCK_MAX_PENDING_FDS 32

enum {
	ANDOCK_RESOLVE = 1,
	ANDOCK_OPEN = 2,
	ANDOCK_READLINK = 3,
	ANDOCK_LIST = 4,
	ANDOCK_MKDIR = 5,
	ANDOCK_UNLINK = 6,
	ANDOCK_RENAME = 7,
	ANDOCK_SYMLINK = 8,
	ANDOCK_CHMOD = 9,
	ANDOCK_TRUNCATE = 10,
	ANDOCK_SOCKET = 11,
	ANDOCK_STATFS = 12,
	ANDOCK_UTIMENS = 13,
	ANDOCK_LINK = 14,
	ANDOCK_LIST_XATTR = 15,
	ANDOCK_GET_XATTR = 16,
	ANDOCK_SET_XATTR = 17,
	ANDOCK_REMOVE_XATTR = 18,
};

#ifndef AT_EMPTY_PATH
#define AT_EMPTY_PATH 0x1000
#endif

#ifndef AT_SYMLINK_FOLLOW
#define AT_SYMLINK_FOLLOW 0x400
#endif

enum {
	ANDOCK_MISSING = 0,
	ANDOCK_FILE = 1,
	ANDOCK_DIRECTORY = 2,
	ANDOCK_SYMLINK_TYPE = 3,
	ANDOCK_OTHER = 4,
	ANDOCK_SOCKET_TYPE = 5,
};

enum {
	ANDOCK_DEREFERENCE_FINAL = 1,
	ANDOCK_ALLOW_MISSING_FINAL = 2,
	ANDOCK_EXECUTABLE = 4,
};

struct AndockResponse {
	int status;
	int type;
	mode_t mode;
	uint64_t size;
	uint64_t inode;
	uint64_t cache_id;
	char *path;
	uint8_t *data;
	size_t data_size;
	int fd;
	int backing_fd;
};

struct AndockFileDescription {
	off_t offset;
	int flags;
	unsigned int references;
};

struct AndockFileLock {
	uint64_t inode;
	int type;
	struct AndockFileDescription *owner;
	struct AndockFileLock *next;
};

struct AndockOpenFile {
	int fd;
	int host_fd;
	nlink_t nlink;
	uint64_t inode;
	uint64_t cache_id;
	char *path;
	struct AndockFileDescription *description;
	bool directory;
	struct AndockOpenFile *next;
};

struct AndockFileTable {
	struct AndockOpenFile *open_files;
};

struct AndockUnixSocketPath {
	char *guest_path;
	char host_name[sizeof(((struct sockaddr_un *) 0)->sun_path) - 1];
	size_t host_name_size;
	struct AndockUnixSocketPath *next;
};

struct AndockUnixSocketTable {
	struct AndockUnixSocketPath *paths;
};

static bool image_active;
static struct AndockFileLock *file_locks;

static void release_file_locks(struct AndockFileDescription *owner)
{
	struct AndockFileLock **cursor = &file_locks;
	while (*cursor != NULL) {
		if (owner == NULL || (*cursor)->owner == owner) {
			struct AndockFileLock *removed = *cursor;
			*cursor = removed->next;
			free(removed);
		} else {
			cursor = &(*cursor)->next;
		}
	}
}

static void release_file_description(struct AndockFileDescription *description)
{
	if (description != NULL && --description->references == 0) {
		release_file_locks(description);
		free(description);
	}
}

static int close_open_file(struct AndockOpenFile *file)
{
	if (file->cache_id != 0 && image_active)
		andock_image_engine_release(file->cache_id);
	if (file->host_fd >= 0)
		close(file->host_fd);
	release_file_description(file->description);
	return 0;
}

enum AndockSocketState {
	ANDOCK_SOCKET_IDLE,
	ANDOCK_SOCKET_CREATED,
	ANDOCK_SOCKET_CONNECTED,
	ANDOCK_SOCKET_RECEIVING,
};

static void add_open_file(Tracee *tracee, int fd, int host_fd,
	const char *path, uint64_t inode, uint64_t cache_id, nlink_t nlink,
	bool is_directory, int flags);

struct AndockBrokerState {
	enum AndockSocketState socket_state;
	int host_socket_fd;
	int host_listener_fd;
	int tracee_channel_fd;
	word_t guest_buffer;
	bool socket_cloexec;
	bool synthetic_result_valid;
	word_t synthetic_result;
	struct sockaddr_un transfer_address;
	socklen_t transfer_address_size;
	struct AndockFileTable *files;
	struct AndockUnixSocketTable *unix_sockets;
	char *pending_path;
	char *pending_executable_path;
	nlink_t pending_nlink;
	uint64_t pending_inode;
	uint64_t pending_cache_id;
	bool pending_is_directory;
	int pending_host_fd;
	int pending_flags;
	bool pending_dirty;
	bool pending_cache_retained;
	bool pending_offset_update;
	off_t pending_offset;
	bool transfer_pending;
	bool transfer_update_input;
	bool transfer_update_output;
	int transfer_input_fd;
	int transfer_output_fd;
	uint64_t transfer_output_cache_id;
	off_t transfer_input_offset;
	off_t transfer_output_offset;
	int pending_fds[ANDOCK_MAX_PENDING_FDS];
	int pending_fds_count;
	word_t recvfrom_address;
	word_t recvfrom_size_address;
	word_t recvfrom_max_size;
	bool recvfrom_pending;
	word_t sendmsg_header;
	struct msghdr sendmsg_original;
	bool sendmsg_pending;
	word_t recvmsg_address;
	word_t recvmsg_size_address;
	word_t recvmsg_max_size;
	bool recvmsg_pending;
};

static void release_pending_cache(struct AndockBrokerState *state)
{
	if (state->pending_cache_retained) {
		andock_image_engine_release(state->pending_cache_id);
		state->pending_cache_retained = false;
	}
}

struct AndockRecvMsgPointers {
	word_t msghdr;
	word_t control;
};

static unsigned int image_extension_users;
static uint64_t image_instance_nonce;
static uint64_t transfer_sequence;

static const FilteredSysnum filtered_sysnums[] = {
	{ PR_close, FILTER_SYSEXIT },
	{ PR_copy_file_range, FILTER_SYSEXIT },
	{ PR_dup, FILTER_SYSEXIT },
	{ PR_dup2, FILTER_SYSEXIT },
	{ PR_dup3, FILTER_SYSEXIT },
	{ PR_fcntl, FILTER_SYSEXIT },
	{ PR_fcntl64, FILTER_SYSEXIT },
	{ PR_fdatasync, FILTER_SYSEXIT },
	{ PR_fallocate, FILTER_SYSEXIT },
	{ PR_flock, FILTER_SYSEXIT },
	{ PR_fsync, FILTER_SYSEXIT },
	{ PR_ftruncate, FILTER_SYSEXIT },
	{ PR_ftruncate64, FILTER_SYSEXIT },
	{ PR_getdents64, FILTER_SYSEXIT },
	{ PR_lseek, FILTER_SYSEXIT },
	{ PR_mmap, FILTER_SYSEXIT },
	{ PR_mmap2, FILTER_SYSEXIT },
	{ PR_msync, FILTER_SYSEXIT },
	{ PR_munmap, FILTER_SYSEXIT },
	{ PR_pread64, FILTER_SYSEXIT },
	{ PR_preadv, FILTER_SYSEXIT },
	{ PR_preadv2, FILTER_SYSEXIT },
	{ PR_pwrite64, FILTER_SYSEXIT },
	{ PR_pwritev, FILTER_SYSEXIT },
	{ PR_pwritev2, FILTER_SYSEXIT },
	{ PR_read, FILTER_SYSEXIT },
	{ PR_readv, FILTER_SYSEXIT },
	{ PR_sendfile, FILTER_SYSEXIT },
	{ PR_sendfile64, FILTER_SYSEXIT },
	{ PR_splice, FILTER_SYSEXIT },
	{ PR_write, FILTER_SYSEXIT },
	{ PR_writev, FILTER_SYSEXIT },
	FILTERED_SYSNUM_END,
};

static uint64_t host_to_be64(uint64_t value)
{
	uint32_t high = htonl((uint32_t) (value >> 32));
	uint32_t low = htonl((uint32_t) value);
	return ((uint64_t) low << 32) | high;
}

static uint64_t be64_to_host(uint64_t value)
{
	return host_to_be64(value);
}

static nlink_t response_nlink(const struct AndockResponse *response)
{
	uint64_t encoded;
	if (response->type == ANDOCK_DIRECTORY)
		return 2;
	if (response->type != ANDOCK_FILE || response->data == NULL
	    || response->data_size != sizeof(encoded))
		return 1;
	memcpy(&encoded, response->data, sizeof(encoded));
	encoded = be64_to_host(encoded);
	return encoded > 0 && encoded <= UINT32_MAX ? (nlink_t) encoded : 1;
}

bool andock_image_enabled(void)
{
	return image_active || getenv("ANDOCK_IMAGE_FD") != NULL;
}

int andock_image_open_host_path(const char *path, int flags)
{
	char prefix[64];
	char *end;
	long fd;
	int duplicate;
	int length;

	if (!andock_image_enabled())
		return open(path, flags);
	length = snprintf(prefix, sizeof(prefix), "/proc/%d/fd/", getpid());
	if (length < 0 || length >= (int) sizeof(prefix)
	    || strncmp(path, prefix, length) != 0)
		return open(path, flags);
	errno = 0;
	fd = strtol(path + length, &end, 10);
	if (errno != 0 || *end != '\0' || fd < 0 || fd > INT_MAX) {
		errno = EBADF;
		return -1;
	}
	duplicate = fcntl((int) fd, F_DUPFD_CLOEXEC, 0);
	if (duplicate >= 0 && lseek(duplicate, 0, SEEK_SET) < 0) {
		int error = errno;
		dprintf(STDERR_FILENO,
			"andock: executable fd %ld seek failed: %s (%d)\n",
			fd, strerror(error), -error);
		close(duplicate);
		errno = error;
		return -1;
	}
	if (duplicate < 0)
		dprintf(STDERR_FILENO,
			"andock: executable fd %ld duplicate failed: %s (%d)\n",
			fd, strerror(errno), -errno);
	return duplicate;
}

static int broker_call(int operation, int flags, int mode,
		const char *path, const char *second_path,
		const void *data, size_t data_size, struct AndockResponse *response)
{
	struct andock_image_result result;
	int status = andock_image_engine_call(
		operation,
		flags,
		(mode_t)mode,
		path,
		second_path,
		data,
		data_size,
		&result
	);
	if (status < 0)
		return status;
	memset(response, 0, sizeof(*response));
	response->type = result.type;
	response->mode = result.mode;
	response->size = result.size;
	response->inode = result.inode;
	response->cache_id = result.cache_id;
	response->path = result.path;
	response->data = result.data;
	response->data_size = result.data_size;
	response->fd = result.guest_fd;
	response->backing_fd = result.backing_fd;
	if ((operation == ANDOCK_RESOLVE || operation == ANDOCK_OPEN ||
		 operation == ANDOCK_LINK) && result.type == ANDOCK_FILE) {
		uint64_t links = host_to_be64(result.links);
		free(response->data);
		response->data = malloc(sizeof(links));
		if (response->data == NULL) {
			if (response->fd >= 0)
				close(response->fd);
			if (response->backing_fd >= 0)
				close(response->backing_fd);
			free(response->path);
			memset(response, 0, sizeof(*response));
			response->fd = -1;
			response->backing_fd = -1;
			return -ENOMEM;
		}
		memcpy(response->data, &links, sizeof(links));
		response->data_size = sizeof(links);
		result.data = NULL;
	}
	result.path = NULL;
	result.data = NULL;
	result.guest_fd = -1;
	result.backing_fd = -1;
	andock_image_result_release(&result);
	return 0;
}

static void free_response(struct AndockResponse *response, bool close_fd)
{
	if (close_fd && response->fd >= 0)
		close(response->fd);
	if (close_fd && response->backing_fd >= 0)
		close(response->backing_fd);
	free(response->path);
	free(response->data);
	memset(response, 0, sizeof(*response));
	response->fd = -1;
	response->backing_fd = -1;
}

static void close_socket_state(struct AndockBrokerState *state)
{
	if (state->host_socket_fd >= 0)
		close(state->host_socket_fd);
	if (state->host_listener_fd >= 0)
		close(state->host_listener_fd);
	state->host_socket_fd = -1;
	state->host_listener_fd = -1;
	state->tracee_channel_fd = -1;
	state->guest_buffer = 0;
	state->socket_cloexec = false;
	state->socket_state = ANDOCK_SOCKET_IDLE;
}

static int initialize_socket_state(struct AndockBrokerState *state)
{
	char *name;
	size_t name_size;
	int status;

	state->host_listener_fd = socket(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC, 0);
	if (state->host_listener_fd < 0)
		return -errno;

	memset(&state->transfer_address, 0, sizeof(state->transfer_address));
	state->transfer_address.sun_family = AF_UNIX;
	status = asprintf(&name, "andock.net.%d.%llu", getpid(),
		(unsigned long long) ++transfer_sequence);
	if (status < 0) {
		close_socket_state(state);
		return -ENOMEM;
	}
	name_size = strlen(name);
	if (name_size + 1 >= sizeof(state->transfer_address.sun_path)) {
		free(name);
		close_socket_state(state);
		return -ENAMETOOLONG;
	}
	memcpy(state->transfer_address.sun_path + 1, name, name_size);
	free(name);
	state->transfer_address_size =
		offsetof(struct sockaddr_un, sun_path) + 1 + name_size;
	if (bind(state->host_listener_fd,
		    (struct sockaddr *) &state->transfer_address,
		    state->transfer_address_size) < 0
	    || listen(state->host_listener_fd, 1) < 0) {
		status = -errno;
		close_socket_state(state);
		return status;
	}
	return 0;
}

static int send_socket_fd(struct AndockBrokerState *state)
{
	struct msghdr message;
	struct iovec iov;
	char byte = 0;
	char control[CMSG_SPACE(sizeof(int))];
	struct cmsghdr *cmsg;
	int client;
	int status;

	client = TEMP_FAILURE_RETRY(accept4(
		state->host_listener_fd, NULL, NULL, SOCK_CLOEXEC));
	if (client < 0)
		return -errno;

	memset(&message, 0, sizeof(message));
	memset(control, 0, sizeof(control));
	iov.iov_base = &byte;
	iov.iov_len = sizeof(byte);
	message.msg_iov = &iov;
	message.msg_iovlen = 1;
	message.msg_control = control;
	message.msg_controllen = sizeof(control);
	cmsg = CMSG_FIRSTHDR(&message);
	cmsg->cmsg_level = SOL_SOCKET;
	cmsg->cmsg_type = SCM_RIGHTS;
	cmsg->cmsg_len = CMSG_LEN(sizeof(int));
	memcpy(CMSG_DATA(cmsg), &state->host_socket_fd, sizeof(int));
	status = TEMP_FAILURE_RETRY(sendmsg(client, &message, MSG_NOSIGNAL));
	if (status < 0)
		status = -errno;
	else
		status = 0;
	close(client);
	return status;
}

static int recvmsg_pointers(Tracee *tracee,
		struct AndockRecvMsgPointers *pointers, word_t guest_buffer,
		bool write_layout)
{
#if defined(ARCH_X86_64) || defined(ARCH_ARM64)
	bool is_32_bit = is_32on64_mode(tracee);
#else
	bool is_32_bit = true;
#endif
	word_t pointer_size = is_32_bit ? 4 : 8;
	word_t end = guest_buffer + sizeof(struct sockaddr_un);
	word_t data = end - 4;
	word_t iov_length = data - pointer_size;
	word_t iov = iov_length - pointer_size;
	word_t message_flags = iov - pointer_size;
	word_t control_length = message_flags - pointer_size;
	word_t control = control_length - pointer_size;
	word_t iov_count = control - pointer_size;
	word_t iov_pointer = iov_count - pointer_size;
	word_t message = iov_pointer - pointer_size * 2;

	if (write_layout) {
		char layout[sizeof(struct sockaddr_un)] = {};
		if (is_32_bit) {
			*(uint32_t *) &layout[iov - guest_buffer] = data;
			*(uint32_t *) &layout[iov_length - guest_buffer] = 1;
			*(uint32_t *) &layout[iov_pointer - guest_buffer] = iov;
			*(uint32_t *) &layout[iov_count - guest_buffer] = 1;
			*(uint32_t *) &layout[control - guest_buffer] = guest_buffer;
			*(uint32_t *) &layout[control_length - guest_buffer] =
				CMSG_SPACE(sizeof(int));
		}
		else {
			*(uint64_t *) &layout[iov - guest_buffer] = data;
			*(uint64_t *) &layout[iov_length - guest_buffer] = 1;
			*(uint64_t *) &layout[iov_pointer - guest_buffer] = iov;
			*(uint64_t *) &layout[iov_count - guest_buffer] = 1;
			*(uint64_t *) &layout[control - guest_buffer] = guest_buffer;
			*(uint64_t *) &layout[control_length - guest_buffer] =
				CMSG_SPACE(sizeof(int));
		}
		if (write_data(tracee, guest_buffer, layout, sizeof(layout)) < 0)
			return -EFAULT;
	}
	pointers->msghdr = message;
	pointers->control = guest_buffer;
	return 0;
}

static int fail_socket_chain(Tracee *tracee, struct AndockBrokerState *state,
		int status)
{
	if (state->tracee_channel_fd >= 0)
		register_chained_syscall(tracee, PR_close,
			state->tracee_channel_fd, 0, 0, 0, 0, 0);
	force_chain_final_result(tracee, status);
	if (state->pending_host_fd >= 0) {
		close(state->pending_host_fd);
		state->pending_host_fd = -1;
	}
	release_pending_cache(state);
	TALLOC_FREE(state->pending_path);
	close_socket_state(state);
	return 1;
}

static int fail_received_fd_transfer(Tracee *tracee,
		struct AndockBrokerState *state, int received_fd, int status)
{
	int close_status;

	if (state->pending_host_fd >= 0) {
		close(state->pending_host_fd);
		state->pending_host_fd = -1;
	}
	release_pending_cache(state);
	TALLOC_FREE(state->pending_path);
	close_status = register_chained_syscall(
		tracee, PR_close, received_fd, 0, 0, 0, 0, 0);
	force_chain_final_result(tracee, status);
	close_socket_state(state);
	return close_status < 0 ? close_status : 1;
}

static struct AndockBrokerState *broker_state(Tracee *tracee)
{
	Extension *extension = get_extension(tracee, andock_image_callback);
	return extension == NULL ? NULL
		: (struct AndockBrokerState *) extension->config;
}

static struct AndockOpenFile *find_open_file(Tracee *tracee, int fd)
{
	struct AndockBrokerState *state = broker_state(tracee);
	struct AndockOpenFile *file =
		state == NULL || state->files == NULL ? NULL : state->files->open_files;
	while (file != NULL) {
		if (file->fd == fd)
			return file;
		file = file->next;
	}
	return NULL;
}

static void update_open_file_links(Tracee *tracee, const char *path,
		nlink_t nlink)
{
	struct AndockBrokerState *state = broker_state(tracee);
	struct AndockOpenFile *file =
		state == NULL || state->files == NULL ? NULL : state->files->open_files;
	while (file != NULL) {
		if (strcmp(file->path, path) == 0)
			file->nlink = nlink;
		file = file->next;
	}
}

static void update_open_file_paths(Tracee *tracee, const char *source,
		const char *target)
{
	struct AndockBrokerState *state = broker_state(tracee);
	struct AndockOpenFile *file = state == NULL || state->files == NULL ?
		NULL : state->files->open_files;
	size_t source_length = strlen(source);
	while (file != NULL) {
		if (strcmp(file->path, source) == 0 ||
			(strncmp(file->path, source, source_length) == 0 &&
			 file->path[source_length] == '/')) {
			const char *suffix = file->path + source_length;
			size_t target_length = strlen(target);
			if (target_length + strlen(suffix) < PATH_MAX) {
				char *updated = talloc_size(
					file, target_length + strlen(suffix) + 1);
				if (updated != NULL) {
					strcpy(updated, target);
					strcat(updated, suffix);
					TALLOC_FREE(file->path);
					file->path = updated;
				}
			}
		}
		file = file->next;
	}
}

static struct AndockOpenFile *find_directory(Tracee *tracee, int fd)
{
	struct AndockOpenFile *file = find_open_file(tracee, fd);
	return file != NULL && file->directory ? file : NULL;
}

bool andock_image_is_kernel_path(const char *path)
{
	return strcmp(path, "/dev") == 0
		|| strncmp(path, "/dev/", strlen("/dev/")) == 0
		|| strcmp(path, "/proc") == 0
		|| strncmp(path, "/proc/", strlen("/proc/")) == 0
		|| strcmp(path, "/sys") == 0
		|| strncmp(path, "/sys/", strlen("/sys/")) == 0;
}

static bool parse_fd_path(const char *path, int *fd)
{
	static const char *prefixes[] = {
		"/proc/self/fd/",
		"/proc/thread-self/fd/",
		"/dev/fd/",
		NULL,
	};
	const char *number = NULL;
	char *end;
	long parsed;
	int index;

	for (index = 0; prefixes[index] != NULL; index++) {
		size_t length = strlen(prefixes[index]);
		if (strncmp(path, prefixes[index], length) == 0) {
			number = path + length;
			break;
		}
	}
	if (number == NULL || *number == '\0')
		return false;
	errno = 0;
	parsed = strtol(number, &end, 10);
	if (errno != 0 || *end != '\0' || parsed < 0 || parsed > INT_MAX)
		return false;
	*fd = (int)parsed;
	return true;
}

static bool standard_fd_path(const char *path, int *fd)
{
	if (strcmp(path, "/dev/stdin") == 0)
		*fd = STDIN_FILENO;
	else if (strcmp(path, "/dev/stdout") == 0)
		*fd = STDOUT_FILENO;
	else if (strcmp(path, "/dev/stderr") == 0)
		*fd = STDERR_FILENO;
	else if (!parse_fd_path(path, fd)
		 || *fd < STDIN_FILENO || *fd > STDERR_FILENO)
		return false;
	return true;
}

static bool standard_fd_reopen_supported(int fd, int flags)
{
	int access = flags & O_ACCMODE;
	int changed_status = O_APPEND | O_NONBLOCK;
#ifdef O_ASYNC
	changed_status |= O_ASYNC;
#endif
#ifdef O_DIRECT
	changed_status |= O_DIRECT;
#endif
#ifdef O_DSYNC
	changed_status |= O_DSYNC;
#endif
#ifdef O_NOATIME
	changed_status |= O_NOATIME;
#endif
#ifdef O_SYNC
	changed_status |= O_SYNC;
#endif
	return access == (fd == STDIN_FILENO ? O_RDONLY : O_WRONLY)
		&& (flags & changed_status) == 0;
}

static bool safe_guest_fd(Tracee *tracee, int fd)
{
	return (fd >= STDIN_FILENO && fd <= STDERR_FILENO)
		|| find_open_file(tracee, fd) != NULL;
}

static const char *synthetic_directory_path(const char *path)
{
	if (strcmp(path, "/dev/fd") == 0
	    || strcmp(path, "/dev/fd/.") == 0)
		return "/proc/self/fd";
	if (strcmp(path, "/dev/fd/..") == 0)
		return "/proc/self";
	if (strcmp(path, "/proc/self/fd/.") == 0)
		return "/proc/self/fd";
	if (strcmp(path, "/proc/self/fd/..") == 0)
		return "/proc/self";
	if (strcmp(path, "/proc/thread-self/fd/.") == 0)
		return "/proc/thread-self/fd";
	if (strcmp(path, "/proc/thread-self/fd/..") == 0)
		return "/proc/thread-self";
	if (strcmp(path, "/proc/self") == 0
	    || strcmp(path, "/proc/self/fd") == 0
	    || strcmp(path, "/proc/thread-self") == 0
	    || strcmp(path, "/proc/thread-self/fd") == 0)
		return path;
	return NULL;
}

static int synthetic_relative_path(Tracee *tracee, int dir_fd,
		const char *path, char result[PATH_MAX])
{
	static const char *self_entries[] = {
		"fd", "cwd", "exe", "root", NULL,
	};
	struct AndockOpenFile *directory;
	const char *base;
	int parsed_fd;
	int status;
	int index;

	if (path[0] == '\0' || path[0] == '/')
		return 0;
	if (dir_fd == AT_FDCWD)
		base = tracee->fs->cwd == NULL
			? NULL : synthetic_directory_path(tracee->fs->cwd);
	else {
		directory = find_directory(tracee, dir_fd);
		base = directory == NULL
			? NULL : synthetic_directory_path(directory->path);
	}
	if (base == NULL)
		return 0;
	if (strcmp(path, ".") == 0) {
		strcpy(result, base);
		return 1;
	}
	if (strcmp(base, "/proc/self/fd") == 0
	    || strcmp(base, "/proc/thread-self/fd") == 0) {
		if (strcmp(path, "..") == 0) {
			strcpy(result, strcmp(base, "/proc/self/fd") == 0
				? "/proc/self" : "/proc/thread-self");
			return 1;
		}
		status = join_paths(2, result, base, path);
		if (status < 0)
			return status;
		return parse_fd_path(result, &parsed_fd) ? 1 : -EACCES;
	}
	for (index = 0; self_entries[index] != NULL; index++) {
		if (strcmp(path, self_entries[index]) == 0) {
			status = join_paths(2, result, base, path);
			return status < 0 ? status : 1;
		}
	}
	return -EACCES;
}

static bool guest_owned_kernel_path(const char *path)
{
	return strcmp(path, "/dev/shm") == 0
		|| strncmp(path, "/dev/shm/", strlen("/dev/shm/")) == 0;
}

static bool pending_host_fd_path(Tracee *tracee, const char *path)
{
	struct AndockBrokerState *state = broker_state(tracee);
	char prefix[64];
	char *end;
	long fd;
	int index;
	int length;

	if (state == NULL)
		return false;
	length = snprintf(prefix, sizeof(prefix), "/proc/%d/fd/", getpid());
	if (length < 0 || length >= (int) sizeof(prefix)
	    || strncmp(path, prefix, (size_t) length) != 0)
		return false;
	errno = 0;
	fd = strtol(path + length, &end, 10);
	if (errno != 0 || *end != '\0' || fd < 0 || fd > INT_MAX)
		return false;
	for (index = 0; index < state->pending_fds_count; index++) {
		if (state->pending_fds[index] == (int) fd)
			return true;
	}
	return false;
}

static int safe_host_kernel_path(Tracee *tracee, const char *path,
		char result[PATH_MAX])
{
	static const char *devices[] = {
		"/dev/null", "/dev/zero", "/dev/full", "/dev/random",
		"/dev/urandom", "/dev/tty", "/dev/ptmx", NULL,
	};
	int fd;
	int index;
	int length;

	if (pending_host_fd_path(tracee, path)) {
		if (strlen(path) >= PATH_MAX)
			return -ENAMETOOLONG;
		strcpy(result, path);
		return 1;
	}
	for (index = 0; devices[index] != NULL; index++) {
		if (strcmp(path, devices[index]) == 0) {
			strcpy(result, path);
			return 1;
		}
	}
	if (strcmp(path, "/dev/stdin") == 0)
		fd = STDIN_FILENO;
	else if (strcmp(path, "/dev/stdout") == 0)
		fd = STDOUT_FILENO;
	else if (strcmp(path, "/dev/stderr") == 0)
		fd = STDERR_FILENO;
	else if (!parse_fd_path(path, &fd))
		return 0;
	if (!safe_guest_fd(tracee, fd))
		return -EACCES;
	length = snprintf(result, PATH_MAX, "/proc/self/fd/%d", fd);
	return length < 0 || length >= PATH_MAX ? -ENAMETOOLONG : 1;
}

static int guest_proc_target(Tracee *tracee, const char *path,
		char result[PATH_MAX])
{
	static const char *roots[] = {
		"/proc/self/root", "/proc/thread-self/root", NULL,
	};
	static const char *cwds[] = {
		"/proc/self/cwd", "/proc/thread-self/cwd", NULL,
	};
	static const char *executables[] = {
		"/proc/self/exe", "/proc/thread-self/exe", NULL,
	};
	struct AndockOpenFile *file;
	const char *suffix;
	int status;
	int fd;
	int index;

	for (index = 0; executables[index] != NULL; index++) {
		if (strcmp(path, executables[index]) == 0) {
			if (tracee->exe == NULL || strlen(tracee->exe) >= PATH_MAX)
				return -ENOENT;
			strcpy(result, tracee->exe);
			return 1;
		}
	}
	for (index = 0; roots[index] != NULL; index++) {
		size_t length = strlen(roots[index]);
		if (strncmp(path, roots[index], length) != 0
		    || (path[length] != '\0' && path[length] != '/'))
			continue;
		suffix = path + length;
		if (*suffix == '\0') {
			strcpy(result, "/");
			return 1;
		}
		status = join_paths(2, result, "/", suffix);
		return status < 0 ? status : 1;
	}
	for (index = 0; cwds[index] != NULL; index++) {
		size_t length = strlen(cwds[index]);
		if (strncmp(path, cwds[index], length) != 0
		    || (path[length] != '\0' && path[length] != '/'))
			continue;
		suffix = path + length;
		if (tracee->fs->cwd == NULL)
			return -ENOENT;
		if (*suffix == '\0') {
			if (strlen(tracee->fs->cwd) >= PATH_MAX)
				return -ENOENT;
			strcpy(result, tracee->fs->cwd);
			return 1;
		}
		status = join_paths(2, result, tracee->fs->cwd, suffix);
		return status < 0 ? status : 1;
	}
	if (!parse_fd_path(path, &fd) || !safe_guest_fd(tracee, fd))
		return 0;
	file = find_open_file(tracee, fd);
	if (file == NULL)
		return 0;
	if (strlen(file->path) >= PATH_MAX)
		return -ENAMETOOLONG;
	strcpy(result, file->path);
	return 1;
}

static int synthetic_link_target(Tracee *tracee, const char *path,
		char result[PATH_MAX])
{
	static const char *roots[] = {
		"/proc/self/root", "/proc/thread-self/root", NULL,
	};
	static const char *cwds[] = {
		"/proc/self/cwd", "/proc/thread-self/cwd", NULL,
	};
	static const char *executables[] = {
		"/proc/self/exe", "/proc/thread-self/exe", NULL,
	};
	struct AndockOpenFile *file;
	int fd;
	int index;
	int length;

	if (strcmp(path, "/dev/stdin") == 0) {
		fd = STDIN_FILENO;
		goto device_fd;
	}
	if (strcmp(path, "/dev/stdout") == 0) {
		fd = STDOUT_FILENO;
		goto device_fd;
	}
	if (strcmp(path, "/dev/stderr") == 0) {
		fd = STDERR_FILENO;
		goto device_fd;
	}
	if (strcmp(path, "/dev/fd") == 0) {
		strcpy(result, "/proc/self/fd");
		return 1;
	}
	for (index = 0; roots[index] != NULL; index++) {
		if (strcmp(path, roots[index]) == 0) {
			strcpy(result, "/");
			return 1;
		}
	}
	for (index = 0; cwds[index] != NULL; index++) {
		if (strcmp(path, cwds[index]) == 0) {
			if (tracee->fs->cwd == NULL
			    || strlen(tracee->fs->cwd) >= PATH_MAX)
				return -ENOENT;
			strcpy(result, tracee->fs->cwd);
			return 1;
		}
	}
	for (index = 0; executables[index] != NULL; index++) {
		if (strcmp(path, executables[index]) == 0) {
			if (tracee->exe == NULL || strlen(tracee->exe) >= PATH_MAX)
				return -ENOENT;
			strcpy(result, tracee->exe);
			return 1;
		}
	}
	if (!parse_fd_path(path, &fd) || !safe_guest_fd(tracee, fd))
		return 0;
	file = find_open_file(tracee, fd);
	if (file != NULL) {
		if (strlen(file->path) >= PATH_MAX)
			return -ENAMETOOLONG;
		strcpy(result, file->path);
		return 1;
	}
	length = snprintf(result, PATH_MAX, "andock:[%s]",
		fd == STDIN_FILENO ? "stdin"
		: fd == STDOUT_FILENO ? "stdout" : "stderr");
	return length < 0 || length >= PATH_MAX ? -ENAMETOOLONG : 1;

device_fd:
	length = snprintf(result, PATH_MAX, "/proc/self/fd/%d", fd);
	return length < 0 || length >= PATH_MAX ? -ENAMETOOLONG : 1;
}

static int guest_path(Tracee *tracee, char result[PATH_MAX], int dir_fd,
		const char *user_path)
{
	const char *base;
	struct AndockOpenFile *directory;

	if (user_path[0] == '/' && andock_image_is_kernel_path(user_path)
	    && !guest_owned_kernel_path(user_path))
		return -EACCES;
	if (user_path[0] == '/')
		base = "/";
	else if (dir_fd == AT_FDCWD)
		base = tracee->fs->cwd;
	else {
		directory = find_directory(tracee, dir_fd);
		if (directory == NULL)
			return -ENOTDIR;
		base = directory->path;
	}
	if (synthetic_directory_path(base) != NULL)
		return -EACCES;
	return join_paths(2, result, base, user_path);
}

static int resolve_with_policy(Tracee *tracee, struct AndockResponse *response,
		int dir_fd, const char *user_path, bool deref_final,
		bool allow_missing, bool executable)
{
	char path[PATH_MAX];
	int flags = deref_final ? ANDOCK_DEREFERENCE_FINAL : 0;
	int status = guest_path(tracee, path, dir_fd, user_path);
	if (status < 0)
		return status;
	if (allow_missing)
		flags |= ANDOCK_ALLOW_MISSING_FINAL;
	if (executable)
		flags |= ANDOCK_EXECUTABLE;
	return broker_call(ANDOCK_RESOLVE, flags, 0, path, NULL, NULL, 0, response);
}

static int resolve(Tracee *tracee, struct AndockResponse *response, int dir_fd,
		const char *user_path, bool deref_final, bool allow_missing)
{
	return resolve_with_policy(tracee, response, dir_fd, user_path,
		deref_final, allow_missing, false);
}

static uint64_t hash_unix_socket_path(const char *path)
{
	const unsigned char *cursor;
	uint64_t hash = UINT64_C(1469598103934665603) ^ image_instance_nonce;
	for (cursor = (const unsigned char *) path; *cursor != '\0'; cursor++) {
		hash ^= *cursor;
		hash *= UINT64_C(1099511628211);
	}
	return hash;
}

static struct AndockUnixSocketPath *find_unix_socket_by_guest(
		struct AndockUnixSocketTable *table, const char *guest_path)
{
	struct AndockUnixSocketPath *entry =
		table == NULL ? NULL : table->paths;
	while (entry != NULL) {
		if (strcmp(entry->guest_path, guest_path) == 0)
			return entry;
		entry = entry->next;
	}
	return NULL;
}

static struct AndockUnixSocketPath *find_unix_socket_by_host(
		struct AndockUnixSocketTable *table, const char *host_name,
		size_t host_name_size)
{
	struct AndockUnixSocketPath *entry =
		table == NULL ? NULL : table->paths;
	while (entry != NULL) {
		if (entry->host_name_size == host_name_size
		    && memcmp(entry->host_name, host_name, host_name_size) == 0)
			return entry;
		entry = entry->next;
	}
	return NULL;
}

int andock_image_translate_unix_socket(Tracee *tracee,
		struct sockaddr_un *address, const char *user_path)
{
	struct AndockBrokerState *state = broker_state(tracee);
	struct AndockResponse response = { .fd = -1, .backing_fd = -1 };
	struct AndockUnixSocketPath *entry;
	int length;
	int status;

	if (state == NULL || state->unix_sockets == NULL)
		return -ENOTCONN;
	status = resolve(tracee, &response, AT_FDCWD, user_path, true, true);
	if (status < 0)
		return status;
	entry = find_unix_socket_by_guest(state->unix_sockets, response.path);
	if (entry == NULL) {
		entry = talloc_zero(state->unix_sockets, struct AndockUnixSocketPath);
		if (entry == NULL) {
			free_response(&response, true);
			return -ENOMEM;
		}
		entry->guest_path = talloc_strdup(entry, response.path);
		if (entry->guest_path == NULL) {
			TALLOC_FREE(entry);
			free_response(&response, true);
			return -ENOMEM;
		}
		length = snprintf(entry->host_name, sizeof(entry->host_name),
			"andock.%016" PRIx64 ".%016" PRIx64,
			image_instance_nonce,
			hash_unix_socket_path(response.path));
		if (length < 0 || (size_t) length >= sizeof(entry->host_name)) {
			TALLOC_FREE(entry);
			free_response(&response, true);
			return -ENAMETOOLONG;
		}
		entry->host_name_size = (size_t) length;
		entry->next = state->unix_sockets->paths;
		state->unix_sockets->paths = entry;
	}
	free_response(&response, true);

	memset(address, 0, sizeof(*address));
	address->sun_family = AF_UNIX;
	memcpy(address->sun_path + 1, entry->host_name, entry->host_name_size);
	return 1;
}

int andock_image_detranslate_unix_socket(Tracee *tracee,
		const struct sockaddr_un *address, socklen_t size,
		char result[PATH_MAX])
{
	struct AndockBrokerState *state = broker_state(tracee);
	struct AndockUnixSocketPath *entry;
	size_t host_name_size;
	size_t guest_size;

	if (state == NULL || state->unix_sockets == NULL
	    || address->sun_family != AF_UNIX || address->sun_path[0] != '\0'
	    || size <= offsetof(struct sockaddr_un, sun_path) + 1)
		return 0;
	host_name_size =
		size - offsetof(struct sockaddr_un, sun_path) - 1;
	if (host_name_size > sizeof(address->sun_path) - 1)
		host_name_size = sizeof(address->sun_path) - 1;
	while (host_name_size > 0
	    && address->sun_path[host_name_size] == '\0')
		host_name_size--;
	entry = find_unix_socket_by_host(
		state->unix_sockets, address->sun_path + 1, host_name_size);
	if (entry == NULL)
		return 0;
	guest_size = strlen(entry->guest_path);
	if (guest_size >= PATH_MAX)
		return -ENAMETOOLONG;
	memcpy(result, entry->guest_path, guest_size + 1);
	return 1;
}

static void keep_pending_fd(Tracee *tracee, int fd)
{
	struct AndockBrokerState *state = broker_state(tracee);
	if (fd < 0)
		return;
	if (state == NULL || state->pending_fds_count >= ANDOCK_MAX_PENDING_FDS) {
		close(fd);
		return;
	}
	state->pending_fds[state->pending_fds_count++] = fd;
}

static void close_pending_fds(Tracee *tracee)
{
	struct AndockBrokerState *state = broker_state(tracee);
	int index;
	if (state == NULL)
		return;
	for (index = 0; index < state->pending_fds_count; index++)
		close(state->pending_fds[index]);
	state->pending_fds_count = 0;
}

static int translate_path_with_policy(Tracee *tracee, char result[PATH_MAX],
		int dir_fd, const char *user_path, bool deref_final,
		bool executable)
{
	struct AndockResponse response = { .fd = -1, .backing_fd = -1 };
	int status;
	if (user_path[0] == '/' && andock_image_is_kernel_path(user_path)) {
		if (guest_owned_kernel_path(user_path))
			goto resolve_image;
		status = guest_proc_target(tracee, user_path, result);
		if (status < 0)
			return status;
		if (status > 0)
			user_path = result;
		else {
			status = safe_host_kernel_path(tracee, user_path, result);
			if (status != 0)
				return status < 0 ? status : 0;
			return -EACCES;
		}
	}

resolve_image:
	status = resolve_with_policy(tracee, &response, dir_fd, user_path,
			deref_final, true, executable);
	if (status < 0)
		return status;
	if (executable && response.type == ANDOCK_FILE
	    && (response.mode & 0111) == 0) {
		free_response(&response, true);
		return -EACCES;
	}

	if (response.type == ANDOCK_FILE && response.fd >= 0) {
		if (executable) {
			struct AndockBrokerState *state = broker_state(tracee);
			if (state == NULL) {
				free_response(&response, true);
				return -ENOTCONN;
			}
			TALLOC_FREE(state->pending_executable_path);
			state->pending_executable_path =
				talloc_strdup(state, response.path);
			if (state->pending_executable_path == NULL) {
				free_response(&response, true);
				return -ENOMEM;
			}
		}
		status = snprintf(result, PATH_MAX, "/proc/%d/fd/%d", getpid(), response.fd);
		if (status < 0 || status >= PATH_MAX) {
			free_response(&response, true);
			return -ENAMETOOLONG;
		}
		keep_pending_fd(tracee, response.fd);
		response.fd = -1;
	}
	else if (response.type == ANDOCK_DIRECTORY)
		strcpy(result, "/system");
	else if (response.type == ANDOCK_SYMLINK_TYPE)
		strcpy(result, "/system/bin/sh");
	else
		strcpy(result, "/__andee_missing__");

	free_response(&response, true);
	return 0;
}

int andock_image_translate_path(Tracee *tracee, char result[PATH_MAX],
		int dir_fd, const char *user_path, bool deref_final)
{
	return translate_path_with_policy(tracee, result, dir_fd, user_path,
		deref_final, false);
}

int andock_image_translate_executable_path(Tracee *tracee,
		char result[PATH_MAX], int dir_fd, const char *user_path,
		bool deref_final)
{
	int status = translate_path_with_policy(tracee, result, dir_fd, user_path,
		deref_final, true);
	if (status < 0)
		dprintf(STDERR_FILENO,
			"andock: executable translation %s failed: %s (%d)\n",
			user_path, strerror(-status), status);
	return status;
}

static int resolve_executable(Tracee *tracee, char result[PATH_MAX],
		const char *path)
{
	struct AndockResponse response = { .fd = -1, .backing_fd = -1 };
	int status = resolve_with_policy(
		tracee, &response, AT_FDCWD, path, true, false, true);
	if (status < 0)
		return status;
	if (response.type != ANDOCK_FILE) {
		free_response(&response, true);
		return -EACCES;
	}
	if (strlen(response.path) >= PATH_MAX) {
		free_response(&response, true);
		return -ENAMETOOLONG;
	}
	strcpy(result, response.path);
	free_response(&response, true);
	return 0;
}

int andock_image_find_executable(Tracee *tracee, char result[PATH_MAX],
		const char *paths, const char *command)
{
	const char *cursor;
	int status;
	if (command == NULL)
		command = "/bin/sh";
	if (strchr(command, '/') != NULL) {
		status = resolve_executable(tracee, result, command);
		if (status < 0)
			dprintf(STDERR_FILENO,
				"andock: cannot resolve initial executable %s: %s (%d)\n",
				command, strerror(-status), status);
		return status;
	}

	paths = paths != NULL ? paths : getenv("PATH");
	if (paths == NULL || paths[0] == '\0')
		return -ENOENT;
	for (cursor = paths; ; ) {
		const char *separator = strchr(cursor, ':');
		size_t length = separator == NULL ? strlen(cursor)
			: (size_t)(separator - cursor);
		char candidate[PATH_MAX];
		int written;
		if (length == 0)
			written = snprintf(candidate, sizeof(candidate), "./%s", command);
		else
			written = snprintf(candidate, sizeof(candidate), "%.*s/%s",
				(int)length, cursor, command);
		if (written >= 0 && written < (int)sizeof(candidate)
		    && resolve_executable(tracee, result, candidate) == 0)
			return 0;
		if (separator == NULL)
			break;
		cursor = separator + 1;
	}
	return -ENOENT;
}

int andock_image_take_executable_path(Tracee *tracee, char result[PATH_MAX])
{
	struct AndockBrokerState *state = broker_state(tracee);
	size_t length;
	if (state == NULL || state->pending_executable_path == NULL)
		return -ENOENT;
	length = strlen(state->pending_executable_path);
	if (length >= PATH_MAX)
		return -ENAMETOOLONG;
	memcpy(result, state->pending_executable_path, length + 1);
	TALLOC_FREE(state->pending_executable_path);
	return 0;
}

static int set_pending_open_file(Tracee *tracee, const char *path,
		uint64_t inode, uint64_t cache_id, nlink_t nlink,
		bool directory, int flags)
{
	struct AndockBrokerState *state = broker_state(tracee);
	if (state == NULL)
		return -ENOTCONN;
	release_pending_cache(state);
	TALLOC_FREE(state->pending_path);
	state->pending_path = talloc_strdup(state, path);
	if (state->pending_path == NULL)
		return -ENOMEM;
	state->pending_nlink = nlink;
	state->pending_inode = inode;
	state->pending_cache_id = cache_id;
	state->pending_is_directory = directory;
	state->pending_flags = flags;
	state->pending_dirty = false;
	return 0;
}

static int broker_open_path(Tracee *tracee, Reg reg, int dir_fd,
		const char *path, int flags, int mode, int *brokered_fd)
{
	struct AndockResponse resolved = { .fd = -1, .backing_fd = -1 };
	struct AndockResponse opened = { .fd = -1, .backing_fd = -1 };
	char guest[PATH_MAX];
	int status;
	*brokered_fd = -1;

	status = resolve(tracee, &resolved, dir_fd, path,
			(flags & O_NOFOLLOW) == 0, (flags & O_CREAT) != 0);
	if (status < 0)
		return status;
	if (resolved.type == ANDOCK_DIRECTORY) {
		status = set_pending_open_file(
			tracee, resolved.path, resolved.inode, 0, 2, true, flags);
		free_response(&resolved, true);
		if (status < 0)
			return status;
		strcpy(guest, "/system");
		return set_sysarg_path(tracee, guest, reg);
	}
	strncpy(guest, resolved.path, sizeof(guest) - 1);
	guest[sizeof(guest) - 1] = '\0';
	free_response(&resolved, true);
	status = broker_call(ANDOCK_OPEN, flags, mode, guest, NULL, NULL, 0, &opened);
	if (status < 0)
		return status;
	if (opened.fd < 0) {
		free_response(&opened, true);
		return -EIO;
	}
	status = set_pending_open_file(tracee, opened.path, opened.inode,
		opened.cache_id, response_nlink(&opened), false, flags);
	if (status < 0) {
		free_response(&opened, true);
		return status;
	}
	struct AndockBrokerState *state = broker_state(tracee);
	if (state == NULL) {
		free_response(&opened, true);
		return -ENOTCONN;
	}
	if (state->pending_host_fd >= 0)
		close(state->pending_host_fd);
	state->pending_host_fd = opened.backing_fd;
	opened.backing_fd = -1;
	*brokered_fd = opened.fd;
	opened.fd = -1;
	free_response(&opened, true);
	return 0;
}

static int reopened_file_flags(int flags)
{
	int reopened = flags & (O_ACCMODE | O_APPEND | O_CLOEXEC | O_NONBLOCK
		| O_DIRECTORY | O_NOCTTY);
#ifdef O_PATH
	reopened |= flags & O_PATH;
#endif
#ifdef O_SYNC
	reopened |= flags & O_SYNC;
#endif
#ifdef O_DSYNC
	reopened |= flags & O_DSYNC;
#endif
	return reopened;
}

static int begin_fd_transfer(Tracee *tracee, struct AndockBrokerState *state,
		int fd, bool close_on_exec);

static int prepare_tracked_fd_reopen(Tracee *tracee, Reg path_reg,
		const char *path, int flags)
{
	struct AndockBrokerState *state = broker_state(tracee);
	struct AndockOpenFile *source;
	char target[] = "/system";
	int guest_backing_fd = -1;
	int host_backing_fd = -1;
	int guest_fd;
	int status;
	bool standard;

	if (!parse_fd_path(path, &guest_fd)
	    && !standard_fd_path(path, &guest_fd))
		return 0;
	source = find_open_file(tracee, guest_fd);
	standard = source == NULL && standard_fd_path(path, &guest_fd);
	if (source == NULL && !standard)
		return 0;
	if ((flags & O_NOFOLLOW) != 0) {
#ifdef O_PATH
		if ((flags & O_PATH) != 0)
			return -EOPNOTSUPP;
#endif
		return -ELOOP;
	}
	if ((flags & (O_CREAT | O_EXCL)) == (O_CREAT | O_EXCL))
		return -EEXIST;
	if (state == NULL)
		return -ENOTCONN;
	if (source == NULL) {
		if ((flags & O_DIRECTORY) != 0)
			return -ENOTDIR;
#ifdef O_PATH
		if ((flags & O_PATH) != 0)
			return -EOPNOTSUPP;
#endif
		if (!standard_fd_reopen_supported(guest_fd, flags))
			return -EOPNOTSUPP;
		set_sysnum(tracee, PR_fcntl);
		poke_reg(tracee, SYSARG_1, guest_fd);
		poke_reg(tracee, SYSARG_2,
			(flags & O_CLOEXEC) != 0 ? F_DUPFD_CLOEXEC : F_DUPFD);
		poke_reg(tracee, SYSARG_3, 0);
		return 1;
	}
	if (source->directory) {
		if ((flags & O_ACCMODE) != O_RDONLY || (flags & O_TRUNC) != 0)
			return -EISDIR;
		status = set_pending_open_file(tracee, source->path, source->inode,
			source->cache_id, source->nlink, true, flags);
		if (status < 0)
			return status;
		status = set_sysarg_path(tracee, target, path_reg);
		if (status < 0) {
			TALLOC_FREE(state->pending_path);
			return status;
		}
		tracee->sysexit_pending = true;
		tracee->restart_how = PTRACE_SYSCALL;
		return 1;
	}
	if ((flags & O_DIRECTORY) != 0)
		return -ENOTDIR;
	if (source->host_fd < 0)
		return -EBADF;
	guest_backing_fd = fcntl(source->host_fd, F_DUPFD_CLOEXEC, 0);
	if (guest_backing_fd < 0)
		return -errno;
	host_backing_fd = fcntl(source->host_fd, F_DUPFD_CLOEXEC, 0);
	if (host_backing_fd < 0) {
		status = -errno;
		close(guest_backing_fd);
		return status;
	}
	status = set_pending_open_file(tracee, source->path, source->inode,
		source->cache_id, source->nlink, source->directory, flags);
	if (status < 0) {
		if (guest_backing_fd >= 0)
			close(guest_backing_fd);
		if (host_backing_fd >= 0)
			close(host_backing_fd);
		return status;
	}
	status = andock_image_engine_retain(source->cache_id);
	if (status < 0) {
		close(guest_backing_fd);
		close(host_backing_fd);
		TALLOC_FREE(state->pending_path);
		return status;
	}
	state->pending_cache_retained = true;
	if (state->pending_host_fd >= 0)
		close(state->pending_host_fd);
	state->pending_host_fd = host_backing_fd;
	state->pending_dirty = (flags & O_TRUNC) != 0;
	status = begin_fd_transfer(
		tracee, state, guest_backing_fd, (flags & O_CLOEXEC) != 0);
	if (status < 0) {
		if (state->pending_host_fd >= 0)
			close(state->pending_host_fd);
		state->pending_host_fd = -1;
		release_pending_cache(state);
		TALLOC_FREE(state->pending_path);
		return status;
	}
	return status;
}

static int begin_fd_transfer(Tracee *tracee, struct AndockBrokerState *state,
		int fd, bool close_on_exec)
{
	int status;
	if (state->socket_state != ANDOCK_SOCKET_IDLE) {
		close(fd);
		return -EBUSY;
	}
	state->host_socket_fd = fd;
	state->socket_cloexec = close_on_exec;
	status = initialize_socket_state(state);
	if (status < 0)
		return status;
	set_sysnum(tracee, PR_socket);
	poke_reg(tracee, SYSARG_1, AF_UNIX);
	poke_reg(tracee, SYSARG_2, SOCK_SEQPACKET | SOCK_CLOEXEC);
	poke_reg(tracee, SYSARG_3, 0);
	tracee->restart_how = PTRACE_SYSCALL;
	state->socket_state = ANDOCK_SOCKET_CREATED;
	return 1;
}

static int handle_open_enter(Extension *extension, Tracee *tracee, Sysnum sysnum)
{
	struct AndockBrokerState *state = extension->config;
	struct proot_open_how how = {};
	char canonical[PATH_MAX];
	char path[PATH_MAX];
	Reg path_reg;
	int dir_fd;
	int flags;
	int mode;
	int status;
	int brokered_fd;
	word_t translated_path;

	if (sysnum == PR_open || sysnum == PR_creat) {
		path_reg = SYSARG_1;
		dir_fd = AT_FDCWD;
		flags = sysnum == PR_creat
			? O_CREAT | O_WRONLY | O_TRUNC
			: (int) peek_reg(tracee, CURRENT, SYSARG_2);
		mode = (int) peek_reg(tracee, CURRENT,
			sysnum == PR_creat ? SYSARG_2 : SYSARG_3);
	}
	else if (sysnum == PR_openat) {
		path_reg = SYSARG_2;
		dir_fd = (int) peek_reg(tracee, CURRENT, SYSARG_1);
		flags = (int) peek_reg(tracee, CURRENT, SYSARG_3);
		mode = (int) peek_reg(tracee, CURRENT, SYSARG_4);
	}
	else if (sysnum == PR_openat2) {
		word_t how_size = peek_reg(tracee, CURRENT, SYSARG_4);
		if (how_size < sizeof(how))
			return -EINVAL;
		status = read_data(tracee, &how,
			peek_reg(tracee, CURRENT, SYSARG_3), sizeof(how));
		if (status < 0)
			return status;
		path_reg = SYSARG_2;
		dir_fd = (int) peek_reg(tracee, CURRENT, SYSARG_1);
		flags = (int) how.flags;
		mode = (int) how.mode;
		set_sysnum(tracee, PR_openat);
		poke_reg(tracee, SYSARG_3, flags);
		poke_reg(tracee, SYSARG_4, mode);
	}
	else
		return 0;

	status = get_sysarg_path(tracee, path, path_reg);
	if (status < 0)
		return status;
	status = synthetic_relative_path(tracee, dir_fd, path, canonical);
	if (status < 0)
		return status;
	if (status > 0) {
		strcpy(path, canonical);
		dir_fd = AT_FDCWD;
	}
	if (path[0] == '/' && andock_image_is_kernel_path(path)) {
		char target[PATH_MAX];
		if (guest_owned_kernel_path(path))
			goto open_image;
		status = prepare_tracked_fd_reopen(tracee, path_reg, path, flags);
		if (status != 0)
			return status;
		const char *synthetic = synthetic_directory_path(path);
		if (synthetic != NULL) {
			status = set_pending_open_file(
				tracee, synthetic, 0, 0, 2, true, flags);
			if (status < 0)
				return status;
			strcpy(target, "/system");
			status = set_sysarg_path(tracee, target, path_reg);
			if (status < 0) {
				TALLOC_FREE(state->pending_path);
				return status;
			}
			goto reopen_directory;
		}
		status = safe_host_kernel_path(tracee, path, target);
		if (status < 0)
			return status;
		if (status > 0)
			return strcmp(path, target) == 0
				? 0 : set_sysarg_path(tracee, target, path_reg);
		status = guest_proc_target(tracee, path, target);
		if (status <= 0)
			return status < 0 ? status : -EACCES;
		strcpy(path, target);
	}

open_image:
	status = broker_open_path(
		tracee, path_reg, dir_fd, path, flags, mode, &brokered_fd);
	if (status < 0) {
		TALLOC_FREE(state->pending_path);
		return status;
	}
	if (brokered_fd >= 0) {
		status = begin_fd_transfer(
			tracee, state, brokered_fd, (flags & O_CLOEXEC) != 0);
		if (status < 0)
			TALLOC_FREE(state->pending_path);
		return status;
	}

reopen_directory:
	translated_path = peek_reg(tracee, CURRENT, path_reg);
	set_sysnum(tracee, PR_openat);
	poke_reg(tracee, SYSARG_1, AT_FDCWD);
	poke_reg(tracee, SYSARG_2, translated_path);
	poke_reg(tracee, SYSARG_3, reopened_file_flags(flags));
	poke_reg(tracee, SYSARG_4, 0);
	tracee->sysexit_pending = true;
	tracee->restart_how = PTRACE_SYSCALL;
	return 1;
}

static int void_result(Tracee *tracee, int64_t result)
{
	Extension *extension = get_extension(tracee, andock_image_callback);
	struct AndockBrokerState *state;
	if (extension == NULL)
		return -ENOTCONN;
	state = extension->config;
	state->synthetic_result = (word_t) result;
	state->synthetic_result_valid = true;
	poke_reg(tracee, SYSARG_RESULT, (word_t) result);
	set_sysnum(tracee, PR_void);
	return 1;
}

static bool file_readable(const struct AndockOpenFile *file)
{
#ifdef O_PATH
	if ((file->description->flags & O_PATH) != 0)
		return false;
#endif
	return (file->description->flags & O_ACCMODE) != O_WRONLY;
}

static bool file_writable(const struct AndockOpenFile *file)
{
#ifdef O_PATH
	if ((file->description->flags & O_PATH) != 0)
		return false;
#endif
	return (file->description->flags & O_ACCMODE) != O_RDONLY;
}

static int settable_status_flags(void)
{
	int flags = O_APPEND | O_NONBLOCK;
#ifdef O_ASYNC
	flags |= O_ASYNC;
#endif
#ifdef O_DIRECT
	flags |= O_DIRECT;
#endif
#ifdef O_NOATIME
	flags |= O_NOATIME;
#endif
	return flags;
}

static int handle_file_control(Tracee *tracee, Sysnum sysnum)
{
	struct AndockOpenFile *file;
	int operation;

	if (sysnum != PR_fcntl && sysnum != PR_fcntl64)
		return 0;
	file = find_open_file(
		tracee, (int)peek_reg(tracee, CURRENT, SYSARG_1));
	if (file == NULL || file->description == NULL)
		return 0;
	operation = (int)peek_reg(tracee, CURRENT, SYSARG_2);
	if (operation == F_GETFL)
		return void_result(tracee, file->description->flags);
	if (operation == F_SETFL) {
		int mutable = settable_status_flags();
		int requested = (int)peek_reg(tracee, CURRENT, SYSARG_3);
		file->description->flags =
			(file->description->flags & ~mutable) | (requested & mutable);
		return void_result(tracee, 0);
	}
	return 0;
}

static int handle_file_access(Tracee *tracee, Sysnum sysnum)
{
	struct AndockOpenFile *file;
	int fd;
	bool read = false;
	bool write = false;

	switch (sysnum) {
	case PR_read:
	case PR_readv:
	case PR_pread64:
	case PR_preadv:
	case PR_preadv2:
		read = true;
		fd = (int)peek_reg(tracee, CURRENT, SYSARG_1);
		break;
	case PR_write:
	case PR_writev:
	case PR_pwrite64:
	case PR_pwritev:
	case PR_pwritev2:
	case PR_ftruncate:
	case PR_ftruncate64:
	case PR_fallocate:
		write = true;
		fd = (int)peek_reg(tracee, CURRENT, SYSARG_1);
		break;
	case PR_mmap:
	case PR_mmap2: {
		fd = (int)peek_reg(tracee, CURRENT, SYSARG_5);
		file = find_open_file(tracee, fd);
		if (file == NULL || file->directory)
			return 0;
		int protection = (int)peek_reg(tracee, CURRENT, SYSARG_3);
		int flags = (int)peek_reg(tracee, CURRENT, SYSARG_4);
		if (!file_readable(file) ||
			((protection & PROT_WRITE) != 0 && (flags & MAP_SHARED) != 0 &&
			 !file_writable(file)))
			return -EACCES;
		return 0;
	}
	default:
		return 0;
	}
	file = find_open_file(tracee, fd);
	if (file == NULL || file->directory)
		return 0;
	return (read && !file_readable(file)) || (write && !file_writable(file))
		? -EBADF : 0;
}

static int handle_positioned_io(Tracee *tracee, Sysnum sysnum)
{
	struct AndockBrokerState *state = broker_state(tracee);
	struct AndockOpenFile *file;
	Sysnum positioned;
	uint64_t offset;
	int fd;

	if (sysnum != PR_read && sysnum != PR_write &&
		sysnum != PR_readv && sysnum != PR_writev)
		return 0;
	fd = (int)peek_reg(tracee, CURRENT, SYSARG_1);
	file = find_open_file(tracee, fd);
	if (state == NULL || file == NULL || file->directory ||
		file->description == NULL)
		return 0;
	if ((sysnum == PR_read || sysnum == PR_readv) && !file_readable(file))
		return -EBADF;
	if ((sysnum == PR_write || sysnum == PR_writev) && !file_writable(file))
		return -EBADF;
	offset = (uint64_t)file->description->offset;
	if ((sysnum == PR_write || sysnum == PR_writev) &&
		(file->description->flags & O_APPEND) != 0) {
		struct stat metadata;
		if (file->host_fd < 0 || fstat(file->host_fd, &metadata) < 0)
			return -errno;
		offset = (uint64_t)metadata.st_size;
	}
	positioned = sysnum == PR_read ? PR_pread64
		: sysnum == PR_write ? PR_pwrite64
		: sysnum == PR_readv ? PR_preadv : PR_pwritev;
	set_sysnum(tracee, positioned);
	if (sysnum == PR_readv || sysnum == PR_writev) {
		poke_reg(tracee, SYSARG_4, (word_t)(uint32_t)offset);
		poke_reg(tracee, SYSARG_5, (word_t)(uint32_t)(offset >> 32));
		poke_reg(tracee, SYSARG_6, 0);
	}
	else {
		poke_reg(tracee, SYSARG_4, (word_t)offset);
		poke_reg(tracee, SYSARG_5, 0);
		poke_reg(tracee, SYSARG_6, 0);
	}
	state->pending_offset_update = true;
	state->pending_offset = (off_t)offset;
	return 1;
}

static int append_loaded_buffer(Tracee *tracee,
		struct AndockOpenFile *file, const uint8_t *buffer, size_t size)
{
	struct stat metadata;
	if (file->host_fd < 0 || fstat(file->host_fd, &metadata) < 0)
		return -errno;
	ssize_t written = pwrite(file->host_fd, buffer, size, metadata.st_size);
	if (written < 0)
		return -errno;
	if (written > 0) {
		file->description->offset = metadata.st_size + written;
		andock_image_engine_mark_dirty(file->cache_id);
	}
	return void_result(tracee, written);
}

static int append_buffer(Tracee *tracee, struct AndockOpenFile *file,
		word_t address, size_t size)
{
	if (size > SSIZE_MAX)
		return -EINVAL;
	if (size == 0)
		return void_result(tracee, 0);
	uint8_t *buffer = malloc(size);
	if (buffer == NULL)
		return -ENOMEM;
	int status = read_data(tracee, buffer, address, size);
	if (status < 0) {
		free(buffer);
		return status;
	}
	status = append_loaded_buffer(tracee, file, buffer, size);
	free(buffer);
	return status;
}

static int handle_append_io(Tracee *tracee, Sysnum sysnum)
{
	if (sysnum != PR_write && sysnum != PR_writev)
		return 0;
	struct AndockOpenFile *file = find_open_file(
		tracee, (int)peek_reg(tracee, CURRENT, SYSARG_1));
	if (file == NULL || file->directory || file->description == NULL ||
		(file->description->flags & O_APPEND) == 0)
		return 0;
	if (!file_writable(file))
		return -EBADF;
	if (sysnum == PR_write)
		return append_buffer(tracee, file,
			peek_reg(tracee, CURRENT, SYSARG_2),
			(size_t)peek_reg(tracee, CURRENT, SYSARG_3));

	int count = (int)peek_reg(tracee, CURRENT, SYSARG_3);
	long maximum = sysconf(_SC_IOV_MAX);
	if (count < 0 || (maximum > 0 && count > maximum))
		return -EINVAL;
	if (count == 0)
		return void_result(tracee, 0);
	if ((size_t)count > SIZE_MAX / sizeof(struct iovec))
		return -EINVAL;
	struct iovec *vectors = malloc((size_t)count * sizeof(*vectors));
	if (vectors == NULL)
		return -ENOMEM;
	int status = read_data(tracee, vectors,
		peek_reg(tracee, CURRENT, SYSARG_2),
		(size_t)count * sizeof(*vectors));
	if (status < 0) {
		free(vectors);
		return status;
	}
	size_t total = 0;
	for (int index = 0; index < count; index++) {
		if (vectors[index].iov_len > (size_t)SSIZE_MAX - total) {
			free(vectors);
			return -EINVAL;
		}
		total += vectors[index].iov_len;
	}
	uint8_t *buffer = total == 0 ? NULL : malloc(total);
	if (total != 0 && buffer == NULL) {
		free(vectors);
		return -ENOMEM;
	}
	size_t offset = 0;
	for (int index = 0; index < count; index++) {
		if (vectors[index].iov_len == 0)
			continue;
		status = read_data(tracee, buffer + offset,
			(word_t)vectors[index].iov_base, vectors[index].iov_len);
		if (status < 0) {
			free(buffer);
			free(vectors);
			return status;
		}
		offset += vectors[index].iov_len;
	}
	free(vectors);
	if (total == 0) {
		free(buffer);
		return void_result(tracee, 0);
	}
	status = append_loaded_buffer(tracee, file, buffer, total);
	free(buffer);
	return status;
}

static int transfer_offset(struct AndockOpenFile *file, bool output,
		off_t *offset)
{
	*offset = file->description->offset;
	if (output && (file->description->flags & O_APPEND) != 0) {
		struct stat metadata;
		if (file->host_fd < 0 || fstat(file->host_fd, &metadata) < 0)
			return -errno;
		*offset = metadata.st_size;
	}
	return 0;
}

static int handle_file_transfer(Tracee *tracee, Sysnum sysnum)
{
	struct AndockBrokerState *state = broker_state(tracee);
	struct AndockOpenFile *input;
	struct AndockOpenFile *output;
	word_t input_pointer;
	word_t output_pointer;
	word_t scratch;
	int input_fd;
	int output_fd;
	int status;
	bool sendfile;

	if (sysnum != PR_sendfile && sysnum != PR_sendfile64 &&
		sysnum != PR_copy_file_range && sysnum != PR_splice)
		return 0;
	sendfile = sysnum == PR_sendfile || sysnum == PR_sendfile64;
	if (sendfile) {
		output_fd = (int)peek_reg(tracee, CURRENT, SYSARG_1);
		input_fd = (int)peek_reg(tracee, CURRENT, SYSARG_2);
		input_pointer = peek_reg(tracee, CURRENT, SYSARG_3);
		output_pointer = 0;
	} else {
		input_fd = (int)peek_reg(tracee, CURRENT, SYSARG_1);
		input_pointer = peek_reg(tracee, CURRENT, SYSARG_2);
		output_fd = (int)peek_reg(tracee, CURRENT, SYSARG_3);
		output_pointer = peek_reg(tracee, CURRENT, SYSARG_4);
	}
	input = find_open_file(tracee, input_fd);
	output = find_open_file(tracee, output_fd);
	if (input == NULL && output == NULL)
		return 0;
	if ((input != NULL && !file_readable(input)) ||
		(output != NULL && !file_writable(output)))
		return -EBADF;
	if (sendfile && output != NULL && input == NULL)
		return -EOPNOTSUPP;
	if (state == NULL)
		return -ENOTCONN;

	state->transfer_pending = false;
	state->transfer_update_input = input != NULL && input_pointer == 0;
	state->transfer_update_output = output != NULL && output_pointer == 0;
	state->transfer_input_fd = input_fd;
	state->transfer_output_fd = output_fd;
	state->transfer_output_cache_id = output == NULL ? 0 : output->cache_id;
	if (state->transfer_update_input) {
		status = transfer_offset(input, false, &state->transfer_input_offset);
		if (status < 0)
			return status;
	}
	if (state->transfer_update_output) {
		status = transfer_offset(output, true, &state->transfer_output_offset);
		if (status < 0)
			return status;
	}

	scratch = (peek_reg(tracee, CURRENT, STACK_POINTER) -
		2 * sizeof(off_t)) & ~(word_t)15;
	if (state->transfer_update_input) {
		input_pointer = scratch;
		status = write_data(tracee, input_pointer,
			&state->transfer_input_offset, sizeof(off_t));
		if (status < 0)
			return status;
	}
	if (state->transfer_update_output) {
		output_pointer = scratch + sizeof(off_t);
		status = write_data(tracee, output_pointer,
			&state->transfer_output_offset, sizeof(off_t));
		if (status < 0)
			return status;
	}

	if (sendfile && output != NULL) {
		set_sysnum(tracee, PR_copy_file_range);
		poke_reg(tracee, SYSARG_1, input_fd);
		poke_reg(tracee, SYSARG_2, input_pointer);
		poke_reg(tracee, SYSARG_3, output_fd);
		poke_reg(tracee, SYSARG_4, output_pointer);
		poke_reg(tracee, SYSARG_5,
			peek_reg(tracee, ORIGINAL, SYSARG_4));
		poke_reg(tracee, SYSARG_6, 0);
	} else {
		poke_reg(tracee, sendfile ? SYSARG_3 : SYSARG_2, input_pointer);
		if (!sendfile)
			poke_reg(tracee, SYSARG_4, output_pointer);
	}
	state->transfer_pending = state->transfer_update_input ||
		state->transfer_update_output || output != NULL;
	return 1;
}

static int flush_open_file(struct AndockOpenFile *file)
{
	if (file == NULL || file->cache_id == 0)
		return 0;
	return andock_image_engine_sync(file->cache_id);
}

static int handle_file_sync(Tracee *tracee, Sysnum sysnum)
{
	if (sysnum != PR_fsync && sysnum != PR_fdatasync && sysnum != PR_close)
		return 0;
	struct AndockOpenFile *file = find_open_file(
		tracee, (int)peek_reg(tracee, CURRENT, SYSARG_1));
	if (file == NULL)
		return 0;
	int status = flush_open_file(file);
	if (status < 0)
		return status;
	return sysnum == PR_close ? 0 : void_result(tracee, 0);
}

static int track_file_mutation(Tracee *tracee, Sysnum sysnum)
{
	int fd = -1;
	switch (sysnum) {
	case PR_write:
	case PR_writev:
	case PR_pwrite64:
	case PR_pwritev:
	case PR_pwritev2:
	case PR_ftruncate:
	case PR_ftruncate64:
	case PR_fallocate:
		fd = (int)peek_reg(tracee, CURRENT, SYSARG_1);
		break;
	case PR_sendfile:
	case PR_sendfile64:
		fd = (int)peek_reg(tracee, CURRENT, SYSARG_1);
		break;
	case PR_splice:
		fd = (int)peek_reg(tracee, CURRENT, SYSARG_3);
		break;
	case PR_copy_file_range:
		fd = (int)peek_reg(tracee, CURRENT, SYSARG_3);
		break;
	case PR_mmap:
	case PR_mmap2: {
		fd = (int)peek_reg(tracee, CURRENT, SYSARG_5);
		struct AndockOpenFile *file = find_open_file(tracee, fd);
		int protection = (int)peek_reg(tracee, CURRENT, SYSARG_3);
		int flags = (int)peek_reg(tracee, CURRENT, SYSARG_4);
		if (file != NULL && file->host_fd >= 0 &&
			(protection & PROT_WRITE) != 0 && (flags & MAP_SHARED) != 0)
			andock_image_engine_mark_dirty(file->cache_id);
		return 0;
	}
	case PR_msync:
	case PR_munmap:
		return andock_image_engine_sync_all();
	default:
		return 0;
	}
	struct AndockOpenFile *file = find_open_file(tracee, fd);
	if (file != NULL && file->host_fd >= 0)
		andock_image_engine_mark_dirty(file->cache_id);
	return 0;
}

static int handle_statfs(Tracee *tracee, Sysnum sysnum)
{
	struct AndockOpenFile *file;
	char path[PATH_MAX];
	char guest[PATH_MAX];
	struct AndockResponse response = { .fd = -1, .backing_fd = -1 };
	struct statfs output = {};
	uint64_t fields[8];
	int status;
	int index;

	if (sysnum != PR_statfs && sysnum != PR_fstatfs)
		return 0;
	if (sysnum == PR_fstatfs) {
		file = find_open_file(tracee,
			(int) peek_reg(tracee, CURRENT, SYSARG_1));
		if (file == NULL)
			return 0;
		if (strlen(file->path) >= sizeof(guest))
			return -ENAMETOOLONG;
		strcpy(guest, file->path);
	}
	else {
		status = get_sysarg_path(tracee, path, SYSARG_1);
		if (status < 0)
			return status;
		status = guest_path(tracee, guest, AT_FDCWD, path);
		if (status < 0)
			return status;
	}
	status = broker_call(ANDOCK_STATFS, 0, 0, guest, NULL,
		NULL, 0, &response);
	if (status < 0)
		return status;
	if (response.data_size != sizeof(fields)) {
		free_response(&response, true);
		return -EPROTO;
	}
	memcpy(fields, response.data, sizeof(fields));
	for (index = 0; index < (int) (sizeof(fields) / sizeof(fields[0])); index++)
		fields[index] = be64_to_host(fields[index]);
	output.f_type = 0xEF53; /* Linux ext2/3/4 magic. */
	output.f_bsize = fields[0];
	output.f_frsize = fields[0];
	output.f_blocks = fields[1];
	output.f_bfree = fields[2];
	output.f_bavail = fields[3];
	output.f_files = fields[4];
	output.f_ffree = fields[5];
	output.f_namelen = fields[6];
	output.f_flags = fields[7];
	status = write_data(tracee,
		peek_reg(tracee, CURRENT, SYSARG_2), &output, sizeof(output));
	free_response(&response, true);
	return status < 0 ? status : void_result(tracee, 0);
}

static int handle_utimensat(Tracee *tracee, Sysnum sysnum)
{
	struct AndockOpenFile *file;
	char path[PATH_MAX];
	char guest[PATH_MAX];
	struct timespec times[2] = {
		{ .tv_nsec = UTIME_NOW },
		{ .tv_nsec = UTIME_NOW },
	};
	uint64_t fields[4];
	struct AndockResponse response = { .fd = -1, .backing_fd = -1 };
	word_t times_address;
	int dir_fd;
	int flags;
	int status;
	bool null_path;

	if (sysnum != PR_utimensat)
		return 0;
	null_path = peek_reg(tracee, CURRENT, SYSARG_2) == 0;
	if (null_path)
		path[0] = '\0';
	else {
		status = get_sysarg_path(tracee, path, SYSARG_2);
		if (status < 0)
			return status;
	}
	if (path[0] == '/' && andock_image_is_kernel_path(path)
	    && !guest_owned_kernel_path(path))
		return -EROFS;
	dir_fd = (int) peek_reg(tracee, CURRENT, SYSARG_1);
	flags = (int) peek_reg(tracee, CURRENT, SYSARG_4);
	if (path[0] == '\0') {
		if (!null_path && (flags & AT_EMPTY_PATH) == 0)
			return -ENOENT;
		file = find_open_file(tracee, dir_fd);
		if (file == NULL)
			return 0;
		if (strlen(file->path) >= sizeof(guest))
			return -ENAMETOOLONG;
		strcpy(guest, file->path);
		flags &= ~AT_EMPTY_PATH;
	}
	else {
		status = guest_path(tracee, guest, dir_fd, path);
		if (status < 0)
			return status;
	}
	times_address = peek_reg(tracee, CURRENT, SYSARG_3);
	if (times_address != 0) {
		status = read_data(tracee, times, times_address, sizeof(times));
		if (status < 0)
			return status;
	}
	fields[0] = host_to_be64((uint64_t) times[0].tv_sec);
	fields[1] = host_to_be64((uint64_t) times[0].tv_nsec);
	fields[2] = host_to_be64((uint64_t) times[1].tv_sec);
	fields[3] = host_to_be64((uint64_t) times[1].tv_nsec);
	status = broker_call(ANDOCK_UTIMENS, flags, 0, guest, NULL,
		fields, sizeof(fields), &response);
	free_response(&response, true);
	return status < 0 ? status : void_result(tracee, 0);
}

static int xattr_target(Tracee *tracee, Sysnum sysnum,
		char guest[PATH_MAX], int *flags)
{
	struct AndockOpenFile *file;
	char path[PATH_MAX];
	bool descriptor;
	bool nofollow;
	int status;

	descriptor = sysnum == PR_fgetxattr || sysnum == PR_flistxattr
		|| sysnum == PR_fsetxattr || sysnum == PR_fremovexattr;
	nofollow = sysnum == PR_lgetxattr || sysnum == PR_llistxattr
		|| sysnum == PR_lsetxattr || sysnum == PR_lremovexattr;
	if (descriptor) {
		file = find_open_file(tracee,
			(int) peek_reg(tracee, CURRENT, SYSARG_1));
		if (file == NULL)
			return 0;
		if (strlen(file->path) >= PATH_MAX)
			return -ENAMETOOLONG;
		strcpy(guest, file->path);
	}
	else {
		status = get_sysarg_path(tracee, path, SYSARG_1);
		if (status < 0)
			return status;
		if (path[0] == '/' && andock_image_is_kernel_path(path)
		    && !guest_owned_kernel_path(path))
			return -EOPNOTSUPP;
		status = guest_path(tracee, guest, AT_FDCWD, path);
		if (status < 0)
			return status;
	}
	*flags = nofollow ? AT_SYMLINK_NOFOLLOW : 0;
	return 1;
}

static int xattr_name(Tracee *tracee, char name[PATH_MAX])
{
	int status = get_sysarg_path(tracee, name, SYSARG_2);
	if (status < 0)
		return status;
	if (name[0] == '\0' || strlen(name) > XATTR_NAME_MAX)
		return -ERANGE;
	return 0;
}

static int xattr_read_result(Tracee *tracee, struct AndockResponse *response,
		word_t address, word_t size)
{
	size_t result_size = response->data_size;
	int status;

	if (size == 0) {
		free_response(response, true);
		return void_result(tracee, result_size);
	}
	if (address == 0) {
		free_response(response, true);
		return -EFAULT;
	}
	if (result_size > size) {
		free_response(response, true);
		return -ERANGE;
	}
	status = write_data(tracee, address, response->data, result_size);
	free_response(response, true);
	return status < 0 ? status : void_result(tracee, result_size);
}

static int handle_getxattr(Tracee *tracee, Sysnum sysnum)
{
	struct AndockResponse response = { .fd = -1, .backing_fd = -1 };
	char guest[PATH_MAX];
	char name[PATH_MAX];
	word_t address;
	word_t size;
	int flags;
	int status;

	if (sysnum != PR_getxattr && sysnum != PR_lgetxattr
	    && sysnum != PR_fgetxattr)
		return 0;
	status = xattr_target(tracee, sysnum, guest, &flags);
	if (status <= 0)
		return status;
	status = xattr_name(tracee, name);
	if (status < 0)
		return status;
	status = broker_call(ANDOCK_GET_XATTR, flags, 0, guest, name,
		NULL, 0, &response);
	if (status < 0)
		return status;
	address = peek_reg(tracee, CURRENT, SYSARG_3);
	size = peek_reg(tracee, CURRENT, SYSARG_4);
	return xattr_read_result(tracee, &response, address, size);
}

static int handle_listxattr(Tracee *tracee, Sysnum sysnum)
{
	struct AndockResponse response = { .fd = -1, .backing_fd = -1 };
	char guest[PATH_MAX];
	word_t address;
	word_t size;
	int flags;
	int status;

	if (sysnum != PR_listxattr && sysnum != PR_llistxattr
	    && sysnum != PR_flistxattr)
		return 0;
	status = xattr_target(tracee, sysnum, guest, &flags);
	if (status <= 0)
		return status;
	status = broker_call(ANDOCK_LIST_XATTR, flags, 0, guest, NULL,
		NULL, 0, &response);
	if (status < 0)
		return status;
	address = peek_reg(tracee, CURRENT, SYSARG_2);
	size = peek_reg(tracee, CURRENT, SYSARG_3);
	return xattr_read_result(tracee, &response, address, size);
}

static int handle_setxattr(Tracee *tracee, Sysnum sysnum)
{
	struct AndockResponse response = { .fd = -1, .backing_fd = -1 };
	char guest[PATH_MAX];
	char name[PATH_MAX];
	uint8_t *value = NULL;
	word_t address;
	word_t size;
	int flags;
	int status;

	if (sysnum != PR_setxattr && sysnum != PR_lsetxattr
	    && sysnum != PR_fsetxattr)
		return 0;
	status = xattr_target(tracee, sysnum, guest, &flags);
	if (status <= 0)
		return status;
	status = xattr_name(tracee, name);
	if (status < 0)
		return status;
	size = peek_reg(tracee, CURRENT, SYSARG_4);
	if (size > XATTR_SIZE_MAX)
		return -E2BIG;
	address = peek_reg(tracee, CURRENT, SYSARG_3);
	if (size > 0 && address == 0)
		return -EFAULT;
	if (size > 0) {
		value = malloc(size);
		if (value == NULL)
			return -ENOMEM;
		status = read_data(tracee, value, address, size);
		if (status < 0) {
			free(value);
			return status;
		}
	}
	flags |= (int) peek_reg(tracee, CURRENT, SYSARG_5);
	status = broker_call(ANDOCK_SET_XATTR, flags, 0, guest, name,
		value, size, &response);
	free(value);
	free_response(&response, true);
	return status < 0 ? status : void_result(tracee, 0);
}

static int handle_removexattr(Tracee *tracee, Sysnum sysnum)
{
	struct AndockResponse response = { .fd = -1, .backing_fd = -1 };
	char guest[PATH_MAX];
	char name[PATH_MAX];
	int flags;
	int status;

	if (sysnum != PR_removexattr && sysnum != PR_lremovexattr
	    && sysnum != PR_fremovexattr)
		return 0;
	status = xattr_target(tracee, sysnum, guest, &flags);
	if (status <= 0)
		return status;
	status = xattr_name(tracee, name);
	if (status < 0)
		return status;
	status = broker_call(ANDOCK_REMOVE_XATTR, flags, 0, guest, name,
		NULL, 0, &response);
	free_response(&response, true);
	return status < 0 ? status : void_result(tracee, 0);
}

static int handle_link(Tracee *tracee, Sysnum sysnum)
{
	struct AndockOpenFile *file;
	struct AndockResponse response = { .fd = -1, .backing_fd = -1 };
	char source[PATH_MAX];
	char target[PATH_MAX];
	char source_guest[PATH_MAX];
	char target_guest[PATH_MAX];
	int source_dir_fd;
	int target_dir_fd;
	int flags;
	int status;

	if (sysnum == PR_link) {
		source_dir_fd = AT_FDCWD;
		target_dir_fd = AT_FDCWD;
		flags = 0;
		status = get_sysarg_path(tracee, source, SYSARG_1);
		if (status < 0)
			return status;
		status = get_sysarg_path(tracee, target, SYSARG_2);
	}
	else if (sysnum == PR_linkat) {
		source_dir_fd = (int) peek_reg(tracee, CURRENT, SYSARG_1);
		target_dir_fd = (int) peek_reg(tracee, CURRENT, SYSARG_3);
		flags = (int) peek_reg(tracee, CURRENT, SYSARG_5);
		if ((flags & ~(AT_EMPTY_PATH | AT_SYMLINK_FOLLOW)) != 0)
			return -EINVAL;
		status = get_sysarg_path(tracee, source, SYSARG_2);
		if (status < 0)
			return status;
		status = get_sysarg_path(tracee, target, SYSARG_4);
	}
	else
		return 0;
	if (status < 0)
		return status;
	if (source[0] == '\0') {
		if ((flags & AT_EMPTY_PATH) == 0)
			return -ENOENT;
		file = find_open_file(tracee, source_dir_fd);
		if (file == NULL)
			return 0;
		if (strlen(file->path) >= sizeof(source_guest))
			return -ENAMETOOLONG;
		strcpy(source_guest, file->path);
		flags &= ~AT_EMPTY_PATH;
	}
	else {
		status = guest_path(tracee, source_guest, source_dir_fd, source);
		if (status < 0)
			return status;
	}
	if (target[0] == '\0')
		return -ENOENT;
	status = guest_path(tracee, target_guest, target_dir_fd, target);
	if (status < 0)
		return status;
	status = broker_call(ANDOCK_LINK, flags, 0, source_guest, target_guest,
		NULL, 0, &response);
	if (status >= 0)
		update_open_file_links(tracee, source_guest, response_nlink(&response));
	free_response(&response, true);
	return status < 0 ? status : void_result(tracee, 0);
}

static int handle_flock(Tracee *tracee, Sysnum sysnum)
{
	struct AndockFileLock *entry;
	struct AndockFileLock *owned = NULL;
	struct AndockOpenFile *file;
	int operation;
	int type;

	if (sysnum != PR_flock)
		return 0;
	file = find_open_file(
		tracee, (int)peek_reg(tracee, CURRENT, SYSARG_1));
	if (file == NULL || file->description == NULL)
		return 0;
	operation = (int) peek_reg(tracee, CURRENT, SYSARG_2);
	if ((operation & ~(LOCK_SH | LOCK_EX | LOCK_UN | LOCK_NB)) != 0)
		return -EINVAL;
	type = operation & (LOCK_SH | LOCK_EX | LOCK_UN);
	if (type != LOCK_SH && type != LOCK_EX && type != LOCK_UN)
		return -EINVAL;
	for (entry = file_locks; entry != NULL; entry = entry->next) {
		if (entry->inode != file->inode)
			continue;
		if (entry->owner == file->description) {
			owned = entry;
			continue;
		}
		if (type != LOCK_UN &&
			(type == LOCK_EX || entry->type == LOCK_EX))
			return (operation & LOCK_NB) != 0
				? -EWOULDBLOCK : -EOPNOTSUPP;
	}
	if (type == LOCK_UN) {
		if (owned != NULL) {
			struct AndockFileLock **cursor = &file_locks;
			while (*cursor != owned)
				cursor = &(*cursor)->next;
			*cursor = owned->next;
			free(owned);
		}
		return void_result(tracee, 0);
	}
	if (owned == NULL) {
		owned = calloc(1, sizeof(*owned));
		if (owned == NULL)
			return -ENOMEM;
		owned->inode = file->inode;
		owned->owner = file->description;
		owned->next = file_locks;
		file_locks = owned;
	}
	owned->type = type;
	return void_result(tracee, 0);
}

static int resolve_stat_path(Tracee *tracee, struct AndockResponse *response,
	int dir_fd, Reg path_reg, int flags);

static int handle_fake_chown(Tracee *tracee, Sysnum sysnum)
{
	struct AndockResponse response = { .fd = -1, .backing_fd = -1 };
	struct AndockOpenFile *file;
	Reg path_reg;
	int dir_fd;
	int flags = 0;
	int status;

	if (sysnum == PR_fchown) {
		file = find_open_file(
			tracee, (int) peek_reg(tracee, CURRENT, SYSARG_1));
		return file == NULL ? 0 : void_result(tracee, 0);
	}
	if (sysnum == PR_chown || sysnum == PR_lchown) {
		dir_fd = AT_FDCWD;
		path_reg = SYSARG_1;
		flags = sysnum == PR_lchown ? AT_SYMLINK_NOFOLLOW : 0;
	}
	else if (sysnum == PR_fchownat) {
		dir_fd = (int) peek_reg(tracee, CURRENT, SYSARG_1);
		path_reg = SYSARG_2;
		flags = (int) peek_reg(tracee, CURRENT, SYSARG_5);
	}
	else
		return 0;
	status = resolve_stat_path(tracee, &response, dir_fd, path_reg, flags);
	free_response(&response, true);
	return status < 0 ? status : void_result(tracee, 0);
}

static int handle_fchmod(Tracee *tracee, Sysnum sysnum)
{
	struct AndockOpenFile *file;
	struct AndockResponse response = { .fd = -1, .backing_fd = -1 };
	int status;
	if (sysnum != PR_fchmod)
		return 0;
	file = find_open_file(
		tracee, (int) peek_reg(tracee, CURRENT, SYSARG_1));
	if (file == NULL)
		return 0;
	status = broker_call(ANDOCK_CHMOD, 0,
		(int) peek_reg(tracee, CURRENT, SYSARG_2),
		file->path, NULL, NULL, 0, &response);
	free_response(&response, true);
	return status < 0 ? status : void_result(tracee, 0);
}

static int synthetic_directory_response(
		const char *path, struct AndockResponse *response)
{
	const char *synthetic = synthetic_directory_path(path);
	if (synthetic == NULL)
		return -ENOENT;
	response->path = strdup(synthetic);
	if (response->path == NULL)
		return -ENOMEM;
	response->type = ANDOCK_DIRECTORY;
	response->mode = S_IFDIR | 0555;
	return 0;
}

static int resolve_stat_path(Tracee *tracee, struct AndockResponse *response,
		int dir_fd, Reg path_reg, int flags)
{
	struct AndockOpenFile *file;
	struct stat metadata;
	char path[PATH_MAX];
	char target[PATH_MAX];
	int status = get_sysarg_path(tracee, path, path_reg);
	if (status < 0)
		return status;
	status = synthetic_relative_path(tracee, dir_fd, path, target);
	if (status < 0)
		return status;
	if (status > 0) {
		strcpy(path, target);
		dir_fd = AT_FDCWD;
	}
	if (path[0] == '/' && andock_image_is_kernel_path(path)) {
		if (guest_owned_kernel_path(path))
			return resolve(tracee, response, dir_fd, path,
				(flags & AT_SYMLINK_NOFOLLOW) == 0, false);
		if ((flags & AT_SYMLINK_NOFOLLOW) != 0) {
			status = synthetic_link_target(tracee, path, target);
			if (status < 0)
				return status;
			if (status > 0) {
				response->path = strdup(path);
				if (response->path == NULL)
					return -ENOMEM;
				response->type = ANDOCK_SYMLINK_TYPE;
				response->mode = S_IFLNK | 0777;
				response->size = strlen(target);
				return 0;
			}
		}
		status = guest_proc_target(tracee, path, target);
		if (status < 0)
			return status;
		if (status > 0)
			return resolve(tracee, response, AT_FDCWD, target, true, false);
		status = safe_host_kernel_path(tracee, path, target);
		if (status < 0)
			return status;
		if (status > 0) {
			if (strcmp(path, target) != 0) {
				status = set_sysarg_path(tracee, target, path_reg);
				if (status < 0)
					return status;
			}
			return 1;
		}
		if (synthetic_directory_path(path) != NULL) {
			return synthetic_directory_response(path, response);
		}
		return -EACCES;
	}
	if (path[0] != '\0')
		return resolve(tracee, response, dir_fd, path,
			(flags & AT_SYMLINK_NOFOLLOW) == 0, false);
	if ((flags & AT_EMPTY_PATH) == 0)
		return -ENOENT;
	file = find_open_file(tracee, dir_fd);
	if (file == NULL)
		return 1;
	if (file->host_fd < 0 && synthetic_directory_path(file->path) != NULL)
		return synthetic_directory_response(file->path, response);
	if (file->host_fd < 0)
		return resolve(tracee, response, AT_FDCWD, file->path,
			(flags & AT_SYMLINK_NOFOLLOW) == 0, false);
	response->fd = fcntl(file->host_fd, F_DUPFD_CLOEXEC, 0);
	if (response->fd < 0)
		return -errno;
	if (fstat(response->fd, &metadata) < 0) {
		status = -errno;
		free_response(response, true);
		return status;
	}
	response->path = strdup(file->path);
	if (response->path == NULL) {
		free_response(response, true);
		return -ENOMEM;
	}
	response->mode = metadata.st_mode;
	response->size = metadata.st_size;
	response->type = S_ISDIR(metadata.st_mode) ? ANDOCK_DIRECTORY
		: S_ISREG(metadata.st_mode) ? ANDOCK_FILE
		: S_ISLNK(metadata.st_mode) ? ANDOCK_SYMLINK_TYPE : ANDOCK_OTHER;
	if (response->type == ANDOCK_FILE) {
		uint64_t encoded = host_to_be64(file->nlink);
		response->data = malloc(sizeof(encoded));
		if (response->data == NULL) {
			free_response(response, true);
			return -ENOMEM;
		}
		memcpy(response->data, &encoded, sizeof(encoded));
		response->data_size = sizeof(encoded);
	}
	return 0;
}

static uint64_t path_inode(const char *path)
{
	uint64_t hash = UINT64_C(1469598103934665603);
	while (*path != '\0') {
		hash ^= (uint8_t) *path++;
		hash *= UINT64_C(1099511628211);
	}
	return hash == 0 ? 1 : hash;
}

static int handle_path_stat(Tracee *tracee, Sysnum sysnum)
{
	struct AndockResponse response = { .fd = -1, .backing_fd = -1 };
	struct stat output = {};
	struct AndockOpenFile *file;
	Reg path_reg;
	Reg output_reg;
	int dir_fd;
	int flags;
	int status;

	if (sysnum == PR_fstat || sysnum == PR_fstat64) {
		file = find_open_file(
			tracee, (int) peek_reg(tracee, CURRENT, SYSARG_1));
		if (file == NULL)
			return 0;
		output_reg = SYSARG_2;
		if (file->host_fd >= 0) {
			if (fstat(file->host_fd, &output) < 0)
				return -errno;
			output.st_dev = 1;
			output.st_nlink = file->nlink;
			output.st_uid = 0;
			output.st_gid = 0;
			status = write_data(tracee,
				peek_reg(tracee, CURRENT, output_reg),
				&output, sizeof(output));
			return status < 0 ? status : void_result(tracee, 0);
		}
		if (synthetic_directory_path(file->path) != NULL)
			status = synthetic_directory_response(file->path, &response);
		else {
			status = resolve(
				tracee, &response, AT_FDCWD, file->path, true, false);
		}
	}
	else if (sysnum == PR_fstatat64 || sysnum == PR_newfstatat) {
		dir_fd = (int) peek_reg(tracee, CURRENT, SYSARG_1);
		path_reg = SYSARG_2;
		output_reg = SYSARG_3;
		flags = (int) peek_reg(tracee, CURRENT, SYSARG_4);
		status = resolve_stat_path(tracee, &response, dir_fd, path_reg, flags);
	}
	else if (sysnum == PR_stat || sysnum == PR_stat64
		 || sysnum == PR_lstat || sysnum == PR_lstat64) {
		dir_fd = AT_FDCWD;
		path_reg = SYSARG_1;
		output_reg = SYSARG_2;
		flags = (sysnum == PR_lstat || sysnum == PR_lstat64)
			? AT_SYMLINK_NOFOLLOW : 0;
		status = resolve_stat_path(tracee, &response, dir_fd, path_reg, flags);
	}
	else
		return 0;
	if (status != 0)
		return status == 1 ? 0 : status;
	if (response.fd >= 0 && fstat(response.fd, &output) < 0) {
		status = -errno;
		free_response(&response, true);
		return status;
	}
	output.st_dev = 1;
	if (response.fd < 0)
		output.st_ino = path_inode(response.path);
	output.st_nlink = response_nlink(&response);
	output.st_mode = response.mode;
	output.st_uid = 0;
	output.st_gid = 0;
	output.st_size = response.size;
	output.st_blksize = 4096;
	output.st_blocks = (response.size + 511) / 512;
	status = write_data(tracee,
		peek_reg(tracee, CURRENT, output_reg), &output, sizeof(output));
	free_response(&response, true);
	return status < 0 ? status : void_result(tracee, 0);
}

static int handle_path_statx(Tracee *tracee, Sysnum sysnum)
{
	struct AndockResponse response = { .fd = -1, .backing_fd = -1 };
	struct stat metadata = {};
	struct statx output = {};
	int flags;
	int status;
	if (sysnum != PR_statx)
		return 0;
	flags = (int) peek_reg(tracee, CURRENT, SYSARG_3);
	status = resolve_stat_path(tracee, &response,
		(int) peek_reg(tracee, CURRENT, SYSARG_1), SYSARG_2, flags);
	if (status != 0)
		return status == 1 ? 0 : status;
	if (response.fd >= 0 && fstat(response.fd, &metadata) < 0) {
		status = -errno;
		free_response(&response, true);
		return status;
	}
	output.stx_mask = STATX_BASIC_STATS;
	output.stx_blksize = 4096;
	output.stx_ino = response.fd >= 0 ? metadata.st_ino : path_inode(response.path);
	output.stx_nlink = response_nlink(&response);
	output.stx_mode = response.mode;
	output.stx_size = response.size;
	output.stx_blocks = (response.size + 511) / 512;
	output.stx_dev_minor = 1;
	output.stx_atime.tv_sec = metadata.st_atim.tv_sec;
	output.stx_atime.tv_nsec = metadata.st_atim.tv_nsec;
	output.stx_btime.tv_sec = metadata.st_ctim.tv_sec;
	output.stx_btime.tv_nsec = metadata.st_ctim.tv_nsec;
	output.stx_ctime.tv_sec = metadata.st_ctim.tv_sec;
	output.stx_ctime.tv_nsec = metadata.st_ctim.tv_nsec;
	output.stx_mtime.tv_sec = metadata.st_mtim.tv_sec;
	output.stx_mtime.tv_nsec = metadata.st_mtim.tv_nsec;
	status = write_data(tracee,
		peek_reg(tracee, CURRENT, SYSARG_5), &output, sizeof(output));
	free_response(&response, true);
	return status < 0 ? status : void_result(tracee, 0);
}

static int handle_path_access(Tracee *tracee, Sysnum sysnum)
{
	struct AndockResponse response = { .fd = -1, .backing_fd = -1 };
	Reg path_reg;
	int dir_fd;
	int mode;
	int status;
	if (sysnum == PR_access) {
		dir_fd = AT_FDCWD;
		path_reg = SYSARG_1;
		mode = (int) peek_reg(tracee, CURRENT, SYSARG_2);
	}
	else if (sysnum == PR_faccessat || sysnum == PR_faccessat2) {
		dir_fd = (int) peek_reg(tracee, CURRENT, SYSARG_1);
		path_reg = SYSARG_2;
		mode = (int) peek_reg(tracee, CURRENT, SYSARG_3);
	}
	else
		return 0;
	status = resolve_stat_path(tracee, &response, dir_fd, path_reg, 0);
	if (status != 0)
		return status == 1 ? 0 : status;
	if ((mode & X_OK) != 0 && (response.mode & 0111) == 0)
		status = -EACCES;
	else if ((mode & R_OK) != 0 && (response.mode & 0444) == 0)
		status = -EACCES;
	else if ((mode & W_OK) != 0 && (response.mode & 0222) == 0)
		status = -EACCES;
	else
		status = 0;
	free_response(&response, true);
	return status < 0 ? status : void_result(tracee, 0);
}

static int handle_chdir(Tracee *tracee, Sysnum sysnum)
{
	struct AndockResponse response = { .fd = -1, .backing_fd = -1 };
	char path[PATH_MAX];
	int status;

	if (sysnum == PR_fchdir) {
		struct AndockOpenFile *directory = find_directory(
			tracee, (int) peek_reg(tracee, CURRENT, SYSARG_1));
		if (directory == NULL)
			return -ENOTDIR;
		TALLOC_FREE(tracee->fs->cwd);
		tracee->fs->cwd = talloc_strdup(tracee->fs, directory->path);
		return tracee->fs->cwd != NULL ? void_result(tracee, 0) : -ENOMEM;
	}
	status = get_sysarg_path(tracee, path, SYSARG_1);
	if (status < 0)
		return status;
	if (path[0] == '/' && andock_image_is_kernel_path(path)) {
		char target[PATH_MAX];
		if (guest_owned_kernel_path(path))
			goto change_image_directory;
		if (synthetic_directory_path(path) != NULL) {
			status = synthetic_directory_response(path, &response);
			if (status < 0)
				return status;
			goto update_cwd;
		}
		status = guest_proc_target(tracee, path, target);
		if (status <= 0)
			return status < 0 ? status : -EACCES;
		strcpy(path, target);
	}

change_image_directory:
	status = resolve(tracee, &response, AT_FDCWD, path, true, false);
	if (status < 0)
		return status;
	if (response.type != ANDOCK_DIRECTORY) {
		free_response(&response, true);
		return -ENOTDIR;
	}

update_cwd:
	TALLOC_FREE(tracee->fs->cwd);
	tracee->fs->cwd = talloc_strdup(tracee->fs, response.path);
	free_response(&response, true);
	return tracee->fs->cwd != NULL ? void_result(tracee, 0) : -ENOMEM;
}

static int handle_file_lseek(Tracee *tracee, Sysnum sysnum)
{
	struct AndockOpenFile *file;
	struct stat metadata;
	int64_t offset;
	int whence;

	if (sysnum != PR_lseek)
		return 0;
	file = find_open_file(tracee,
		(int) peek_reg(tracee, CURRENT, SYSARG_1));
	if (file == NULL || file->description == NULL)
		return 0;
	offset = (int64_t) peek_reg(tracee, CURRENT, SYSARG_2);
	whence = (int) peek_reg(tracee, CURRENT, SYSARG_3);
	if (whence == SEEK_CUR)
		offset += file->description->offset;
	else if (whence == SEEK_END) {
		if (file->directory || file->host_fd < 0 ||
			fstat(file->host_fd, &metadata) < 0)
			return file->directory ? -EINVAL : -errno;
		offset += metadata.st_size;
	}
	else if (whence != SEEK_SET)
		return -EINVAL;
	if (offset < 0)
		return -EINVAL;
	file->description->offset = (off_t)offset;
	return void_result(tracee, offset);
}

static int mutation_path(Tracee *tracee, int operation, int dir_fd, Reg path_reg,
		int flags, int mode, const char *second)
{
	char path[PATH_MAX];
	char guest[PATH_MAX];
	struct AndockResponse response = { .fd = -1, .backing_fd = -1 };
	int status = get_sysarg_path(tracee, path, path_reg);
	if (status < 0)
		return status;
	if (path[0] == '/' && andock_image_is_kernel_path(path)
	    && !guest_owned_kernel_path(path))
		return -EROFS;
	status = guest_path(tracee, guest, dir_fd, path);
	if (status < 0)
		return status;
	status = broker_call(operation, flags, mode, guest, second, NULL, 0, &response);
	free_response(&response, true);
	return status < 0 ? status : void_result(tracee, 0);
}

static int handle_truncate(Tracee *tracee, Reg path_reg, Reg length_reg)
{
	char path[PATH_MAX];
	char guest[PATH_MAX];
	struct AndockResponse response = { .fd = -1, .backing_fd = -1 };
	uint64_t length = host_to_be64(
		(uint64_t) peek_reg(tracee, CURRENT, length_reg));
	int status = get_sysarg_path(tracee, path, path_reg);
	if (status < 0)
		return status;
	status = guest_path(tracee, guest, AT_FDCWD, path);
	if (status < 0)
		return status;
	status = broker_call(ANDOCK_TRUNCATE, 0, 0, guest, NULL,
		&length, sizeof(length), &response);
	free_response(&response, true);
	return status < 0 ? status : void_result(tracee, 0);
}

static int handle_readlink(Tracee *tracee, Sysnum sysnum)
{
	char path[PATH_MAX];
	char guest[PATH_MAX];
	struct AndockResponse response = { .fd = -1, .backing_fd = -1 };
	Reg path_reg = sysnum == PR_readlink ? SYSARG_1 : SYSARG_2;
	Reg buffer_reg = sysnum == PR_readlink ? SYSARG_2 : SYSARG_3;
	Reg size_reg = sysnum == PR_readlink ? SYSARG_3 : SYSARG_4;
	int dir_fd = sysnum == PR_readlink ? AT_FDCWD
		: (int) peek_reg(tracee, CURRENT, SYSARG_1);
	size_t size = (size_t) peek_reg(tracee, CURRENT, size_reg);
	int status = get_sysarg_path(tracee, path, path_reg);
	if (status < 0)
		return status;
	if (size == 0)
		return -EINVAL;
	status = synthetic_relative_path(tracee, dir_fd, path, guest);
	if (status < 0)
		return status;
	if (status > 0) {
		strcpy(path, guest);
		dir_fd = AT_FDCWD;
	}
	status = synthetic_link_target(tracee, path, guest);
	if (status < 0)
		return status;
	if (status > 0) {
		size_t length = strlen(guest);
		if (size > length)
			size = length;
		status = write_data(tracee,
			peek_reg(tracee, CURRENT, buffer_reg), guest, size);
		return status < 0 ? status : void_result(tracee, size);
	}
	if (path[0] == '/' && andock_image_is_kernel_path(path)) {
		if (guest_owned_kernel_path(path))
			goto read_image_link;
		status = safe_host_kernel_path(tracee, path, guest);
		if (status != 0)
			return status > 0 ? 0 : status;
		status = guest_proc_target(tracee, path, guest);
		if (status <= 0)
			return status < 0 ? status : -EACCES;
		strcpy(path, guest);
	}

read_image_link:
	status = guest_path(tracee, guest, dir_fd, path);
	if (status < 0)
		return status;
	status = broker_call(ANDOCK_READLINK, 0, 0, guest, NULL, NULL, 0, &response);
	if (status < 0)
		return status;
	if (size > response.data_size)
		size = response.data_size;
	status = write_data(tracee, peek_reg(tracee, CURRENT, buffer_reg), response.data, size);
	free_response(&response, true);
	return status < 0 ? status : void_result(tracee, size);
}

struct linux_dirent64_local {
	uint64_t ino;
	int64_t off;
	uint16_t reclen;
	uint8_t type;
	char name[];
};

static uint8_t dirent_type(int type)
{
	switch (type) {
	case ANDOCK_FILE: return DT_REG;
	case ANDOCK_DIRECTORY: return DT_DIR;
	case ANDOCK_SYMLINK_TYPE: return DT_LNK;
	default: return DT_UNKNOWN;
	}
}

static int emit_dirent(uint8_t *output, size_t output_size, size_t *used,
		const char *name, size_t name_size, int type, size_t offset)
{
	size_t record_size = (offsetof(struct linux_dirent64_local, name)
		+ name_size + 1 + 7) & ~((size_t) 7);
	struct linux_dirent64_local *entry;
	if (*used + record_size > output_size)
		return -ENOSPC;
	entry = (struct linux_dirent64_local *) (output + *used);
	memset(entry, 0, record_size);
	entry->ino = offset + 1;
	entry->off = offset + 1;
	entry->reclen = record_size;
	entry->type = dirent_type(type);
	memcpy(entry->name, name, name_size);
	*used += record_size;
	return 0;
}

static int emit_synthetic_entry(uint8_t *output, size_t output_size,
		size_t *used, size_t *logical, off_t offset, const char *name,
		int type)
{
	int status;
	if (offset > (off_t)*logical) {
		(*logical)++;
		return 0;
	}
	status = emit_dirent(output, output_size, used, name, strlen(name),
		type, *logical);
	if (status >= 0)
		(*logical)++;
	return status;
}

static int emit_proc_directory(Tracee *tracee,
		struct AndockOpenFile *directory, uint8_t *output,
		size_t output_size, size_t *used)
{
	static const char *self_entries[] = {
		"fd", "cwd", "exe", "root", NULL,
	};
	struct AndockBrokerState *state = broker_state(tracee);
	struct AndockOpenFile *file;
	size_t logical = 0;
	int previous_fd = STDERR_FILENO;
	int status;
	int index;

	status = emit_synthetic_entry(output, output_size, used, &logical,
		directory->description->offset, ".", ANDOCK_DIRECTORY);
	if (status < 0)
		goto done;
	status = emit_synthetic_entry(output, output_size, used, &logical,
		directory->description->offset, "..", ANDOCK_DIRECTORY);
	if (status < 0)
		goto done;
	if (strcmp(directory->path, "/proc/self") == 0
	    || strcmp(directory->path, "/proc/thread-self") == 0) {
		for (index = 0; self_entries[index] != NULL; index++) {
			status = emit_synthetic_entry(output, output_size, used,
				&logical, directory->description->offset,
				self_entries[index], strcmp(self_entries[index], "fd") == 0
					? ANDOCK_DIRECTORY : ANDOCK_SYMLINK_TYPE);
			if (status < 0)
				goto done;
		}
	}
	else {
		for (index = STDIN_FILENO; index <= STDERR_FILENO; index++) {
			char name[16];
			snprintf(name, sizeof(name), "%d", index);
			status = emit_synthetic_entry(output, output_size, used,
				&logical, directory->description->offset,
				name, ANDOCK_SYMLINK_TYPE);
			if (status < 0)
				goto done;
		}
		while (true) {
			int next_fd = INT_MAX;
			file = state == NULL || state->files == NULL ? NULL
				: state->files->open_files;
			while (file != NULL) {
				if (file->fd > previous_fd && file->fd < next_fd)
					next_fd = file->fd;
				file = file->next;
			}
			if (next_fd == INT_MAX)
				break;
			char name[16];
			snprintf(name, sizeof(name), "%d", next_fd);
			status = emit_synthetic_entry(output, output_size,
				used, &logical, directory->description->offset,
				name, ANDOCK_SYMLINK_TYPE);
			if (status < 0)
				goto done;
			previous_fd = next_fd;
		}
	}
	status = 0;

done:
	if (*used > 0)
		directory->description->offset = (off_t)logical;
	return status == -ENOSPC && *used > 0 ? 0 : status;
}

static int handle_getdents(Tracee *tracee, Sysnum sysnum)
{
	struct AndockOpenFile *directory;
	struct AndockResponse response = { .fd = -1, .backing_fd = -1 };
	uint8_t *output;
	size_t output_size;
	size_t used = 0;
	size_t index = 0;
	size_t logical = 0;
	int status;

	if (sysnum != PR_getdents64)
		return 0;
	directory = find_directory(tracee, (int) peek_reg(tracee, CURRENT, SYSARG_1));
	if (directory == NULL)
		return 0;
	output_size = (size_t) peek_reg(tracee, CURRENT, SYSARG_3);
	if (output_size == 0)
		return -EINVAL;
	output = calloc(1, output_size);
	if (output == NULL)
		return -ENOMEM;
	if (synthetic_directory_path(directory->path) != NULL) {
		status = emit_proc_directory(
			tracee, directory, output, output_size, &used);
		if (status < 0)
			goto fail;
		status = write_data(tracee,
			peek_reg(tracee, CURRENT, SYSARG_2), output, used);
		if (status >= 0)
			status = void_result(tracee, used);
		goto fail;
	}
	status = broker_call(ANDOCK_LIST, 0, 0, directory->path, NULL, NULL, 0, &response);
	if (status < 0) {
		free(output);
		return status;
	}
	if (directory->description->offset <= (off_t)logical) {
		status = emit_dirent(output, output_size, &used, ".", 1,
			ANDOCK_DIRECTORY, logical++);
		if (status < 0)
			goto done;
	}
	else logical++;
	if (directory->description->offset <= (off_t)logical) {
		status = emit_dirent(output, output_size, &used, "..", 2,
			ANDOCK_DIRECTORY, logical++);
		if (status < 0)
			goto done;
	}
	else logical++;
	while (index + 4 <= response.data_size) {
		uint16_t name_size;
		int type;
		memcpy(&name_size, response.data + index, 2);
		name_size = ntohs(name_size);
		type = response.data[index + 2];
		index += 4;
		if (index + name_size > response.data_size) {
			status = -EPROTO;
			goto fail;
		}
		if (directory->description->offset <= (off_t)logical) {
			status = emit_dirent(output, output_size, &used,
				(char *) response.data + index, name_size, type, logical);
			if (status < 0)
				goto done;
		}
		logical++;
		index += name_size;
	}
	status = 0;
done:
	if (used > 0)
		directory->description->offset = (off_t)logical;
	if (status == -ENOSPC && used > 0)
		status = 0;
	if (status == 0) {
		status = write_data(tracee, peek_reg(tracee, CURRENT, SYSARG_2), output, used);
		if (status >= 0)
			status = void_result(tracee, used);
	}
fail:
	free(output);
	free_response(&response, true);
	return status;
}

static int handle_socket_chain(Tracee *tracee, struct AndockBrokerState *state)
{
	struct AndockRecvMsgPointers pointers;
	struct cmsghdr cmsg;
	word_t received_fd;
	int result = (int) peek_reg(tracee, CURRENT, SYSARG_RESULT);
	int status;

	switch (state->socket_state) {
	case ANDOCK_SOCKET_CREATED:
		if (result < 0) {
			close_socket_state(state);
			return 0;
		}
		state->tracee_channel_fd = result;
		state->guest_buffer = peek_reg(tracee, CURRENT, STACK_POINTER)
			- sizeof(struct sockaddr_un);
		if (state->guest_buffer == 0
		    || write_data(tracee, state->guest_buffer,
			&state->transfer_address, sizeof(state->transfer_address)) < 0)
			return fail_socket_chain(tracee, state, -EFAULT);
		status = register_chained_syscall(tracee, PR_connect,
			state->tracee_channel_fd, state->guest_buffer,
			state->transfer_address_size, 0, 0, 0);
		if (status < 0)
			return fail_socket_chain(tracee, state, status);
		state->socket_state = ANDOCK_SOCKET_CONNECTED;
		return 1;

	case ANDOCK_SOCKET_CONNECTED:
		if (result < 0)
			return fail_socket_chain(tracee, state, result);
		status = send_socket_fd(state);
		if (status < 0)
			return fail_socket_chain(tracee, state, status);
		status = recvmsg_pointers(tracee, &pointers,
			state->guest_buffer, true);
		if (status < 0)
			return fail_socket_chain(tracee, state, status);
		status = register_chained_syscall(tracee, PR_recvmsg,
			state->tracee_channel_fd, pointers.msghdr,
			state->socket_cloexec ? MSG_CMSG_CLOEXEC : 0, 0, 0, 0);
		if (status < 0)
			return fail_socket_chain(tracee, state, status);
		state->socket_state = ANDOCK_SOCKET_RECEIVING;
		return 1;

	case ANDOCK_SOCKET_RECEIVING:
		if (result < 0)
			return fail_socket_chain(tracee, state, result);
		status = recvmsg_pointers(tracee, &pointers,
			state->guest_buffer, false);
		if (status < 0)
			return fail_socket_chain(tracee, state, status);
		memset(&cmsg, 0, sizeof(cmsg));
		if (read_data(tracee, &cmsg, pointers.control, sizeof(cmsg)) < 0
		    || cmsg.cmsg_level != SOL_SOCKET || cmsg.cmsg_type != SCM_RIGHTS
		    || cmsg.cmsg_len < CMSG_LEN(sizeof(int)))
			return fail_socket_chain(tracee, state, -EPROTO);
		received_fd = 0;
		if (read_data(tracee, &received_fd,
			pointers.control + sizeof(cmsg), sizeof(int)) < 0
		    || received_fd > INT_MAX)
			return fail_socket_chain(tracee, state, -EPROTO);
		if (state->pending_path != NULL) {
			int host_fd = state->pending_host_fd;
			if (state->pending_dirty) {
				if (state->pending_cache_id == 0 || host_fd < 0)
					return fail_received_fd_transfer(
						tracee, state, (int) received_fd, -EIO);
				if (ftruncate(host_fd, 0) < 0)
					return fail_received_fd_transfer(
						tracee, state, (int) received_fd, -errno);
				andock_image_engine_mark_dirty(state->pending_cache_id);
			}
			state->pending_host_fd = -1;
			add_open_file(tracee, (int) received_fd, host_fd,
				state->pending_path, state->pending_inode,
				state->pending_cache_id, state->pending_nlink,
				state->pending_is_directory, state->pending_flags);
			release_pending_cache(state);
			TALLOC_FREE(state->pending_path);
		}
		register_chained_syscall(tracee, PR_close,
			state->tracee_channel_fd, 0, 0, 0, 0, 0);
		force_chain_final_result(tracee, received_fd);
		close_socket_state(state);
		return 1;

	case ANDOCK_SOCKET_IDLE:
		return 0;
	}
	return -EINVAL;
}

static int handle_unix_socket_enter(Tracee *tracee,
		struct AndockBrokerState *state, Sysnum sysnum)
{
	struct msghdr message;
	word_t header;
	word_t address;
	word_t size_address;
	word_t size;
	int status;

	state->recvfrom_pending = false;
	state->sendmsg_pending = false;
	state->recvmsg_pending = false;
	if (sysnum == PR_sendto) {
		address = peek_reg(tracee, CURRENT, SYSARG_5);
		size = peek_reg(tracee, CURRENT, SYSARG_6);
		status = translate_socketcall_enter(tracee, &address, size);
		if (status <= 0)
			return status;
		poke_reg(tracee, SYSARG_5, address);
		poke_reg(tracee, SYSARG_6, sizeof(struct sockaddr_un));
		return 0;
	}
	if (sysnum == PR_sendmsg) {
		header = peek_reg(tracee, CURRENT, SYSARG_2);
		if (header == 0)
			return 0;
		status = read_data(tracee, &message, header, sizeof(message));
		if (status < 0)
			return status;
		address = (word_t) message.msg_name;
		status = translate_socketcall_enter(
			tracee, &address, message.msg_namelen);
		if (status <= 0)
			return status;
		state->sendmsg_header = header;
		state->sendmsg_original = message;
		state->sendmsg_pending = true;
		message.msg_name = (void *) address;
		message.msg_namelen = sizeof(struct sockaddr_un);
		return write_data(tracee, header, &message, sizeof(message));
	}
	if (sysnum == PR_recvmsg) {
		header = peek_reg(tracee, CURRENT, SYSARG_2);
		if (header == 0)
			return 0;
		status = read_data(tracee, &message, header, sizeof(message));
		if (status < 0)
			return status;
		if (message.msg_name == NULL || message.msg_namelen == 0)
			return 0;
		state->recvmsg_address = (word_t) message.msg_name;
		state->recvmsg_size_address =
			header + offsetof(struct msghdr, msg_namelen);
		state->recvmsg_max_size = message.msg_namelen;
		state->recvmsg_pending = true;
		return 0;
	}
	if (sysnum != PR_recvfrom)
		return 0;
	address = peek_reg(tracee, CURRENT, SYSARG_5);
	size_address = peek_reg(tracee, CURRENT, SYSARG_6);
	if (address == 0 || size_address == 0)
		return 0;
	errno = 0;
	size = (word_t) peek_int32(tracee, size_address);
	if (errno != 0)
		return -errno;
	state->recvfrom_address = address;
	state->recvfrom_size_address = size_address;
	state->recvfrom_max_size = size;
	state->recvfrom_pending = true;
	return 0;
}

static int handle_enter(Extension *extension, Tracee *tracee)
{
	struct AndockBrokerState *state = extension->config;
	Sysnum sysnum = get_sysnum(tracee, ORIGINAL);
	int status;
	char first[PATH_MAX];
	char second[PATH_MAX];
	char first_guest[PATH_MAX];
	char second_guest[PATH_MAX];
	struct AndockResponse response = { .fd = -1, .backing_fd = -1 };

	status = handle_file_sync(tracee, sysnum);
	if (status != 0)
		return status;
	status = handle_file_control(tracee, sysnum);
	if (status != 0)
		return status;
	status = handle_file_access(tracee, sysnum);
	if (status != 0)
		return status;
	status = handle_file_transfer(tracee, sysnum);
	if (status != 0)
		return status;
	status = handle_append_io(tracee, sysnum);
	if (status != 0)
		return status;
	status = track_file_mutation(tracee, sysnum);
	if (status != 0)
		return status;
	status = handle_positioned_io(tracee, sysnum);
	if (status != 0)
		return status;
	status = handle_unix_socket_enter(tracee, state, sysnum);
	if (status != 0)
		return status;
	status = handle_flock(tracee, sysnum);
	if (status != 0)
		return status;
	status = handle_fake_chown(tracee, sysnum);
	if (status != 0)
		return status;
	status = handle_fchmod(tracee, sysnum);
	if (status != 0)
		return status;

	status = handle_open_enter(extension, tracee, sysnum);
	if (status != 0)
		return status;
	status = handle_path_stat(tracee, sysnum);
	if (status != 0)
		return status;
	status = handle_path_statx(tracee, sysnum);
	if (status != 0)
		return status;
	status = handle_statfs(tracee, sysnum);
	if (status != 0)
		return status;
	status = handle_utimensat(tracee, sysnum);
	if (status != 0)
		return status;
	status = handle_getxattr(tracee, sysnum);
	if (status != 0)
		return status;
	status = handle_listxattr(tracee, sysnum);
	if (status != 0)
		return status;
	status = handle_setxattr(tracee, sysnum);
	if (status != 0)
		return status;
	status = handle_removexattr(tracee, sysnum);
	if (status != 0)
		return status;
	status = handle_link(tracee, sysnum);
	if (status != 0)
		return status;
	status = handle_path_access(tracee, sysnum);
	if (status != 0)
		return status;
	if (sysnum == PR_chdir || sysnum == PR_fchdir)
		return handle_chdir(tracee, sysnum);
	status = handle_file_lseek(tracee, sysnum);
	if (status != 0)
		return status;
	if (sysnum == PR_getdents64)
		return handle_getdents(tracee, sysnum);
	if (sysnum == PR_readlink || sysnum == PR_readlinkat)
		return handle_readlink(tracee, sysnum);

	switch (sysnum) {
	case PR_mkdir:
		return mutation_path(tracee, ANDOCK_MKDIR, AT_FDCWD, SYSARG_1,
			0, (int) peek_reg(tracee, CURRENT, SYSARG_2), NULL);
	case PR_mkdirat:
		return mutation_path(tracee, ANDOCK_MKDIR,
			(int) peek_reg(tracee, CURRENT, SYSARG_1), SYSARG_2,
			0, (int) peek_reg(tracee, CURRENT, SYSARG_3), NULL);
	case PR_unlink:
	case PR_rmdir:
		return mutation_path(tracee, ANDOCK_UNLINK, AT_FDCWD, SYSARG_1,
			sysnum == PR_rmdir ? AT_REMOVEDIR : 0, 0, NULL);
	case PR_unlinkat:
		return mutation_path(tracee, ANDOCK_UNLINK,
			(int) peek_reg(tracee, CURRENT, SYSARG_1), SYSARG_2,
			(int) peek_reg(tracee, CURRENT, SYSARG_3), 0, NULL);
	case PR_chmod:
		return mutation_path(tracee, ANDOCK_CHMOD, AT_FDCWD, SYSARG_1,
			0, (int) peek_reg(tracee, CURRENT, SYSARG_2), NULL);
	case PR_fchmodat:
		return mutation_path(tracee, ANDOCK_CHMOD,
			(int) peek_reg(tracee, CURRENT, SYSARG_1), SYSARG_2,
			0, (int) peek_reg(tracee, CURRENT, SYSARG_3), NULL);
	case PR_truncate:
	case PR_truncate64:
		return handle_truncate(tracee, SYSARG_1, SYSARG_2);
	case PR_rename:
		status = get_sysarg_path(tracee, first, SYSARG_1);
		if (status < 0) return status;
		status = get_sysarg_path(tracee, second, SYSARG_2);
		if (status < 0) return status;
		status = guest_path(tracee, first_guest, AT_FDCWD, first);
		if (status < 0) return status;
		status = guest_path(tracee, second_guest, AT_FDCWD, second);
		if (status < 0) return status;
		status = broker_call(ANDOCK_RENAME, 0, 0, first_guest, second_guest,
			NULL, 0, &response);
		if (status >= 0)
			update_open_file_paths(tracee, first_guest, response.path);
		free_response(&response, true);
		return status < 0 ? status : void_result(tracee, 0);
	case PR_renameat:
	case PR_renameat2:
		status = get_sysarg_path(tracee, first, SYSARG_2);
		if (status < 0) return status;
		status = get_sysarg_path(tracee, second, SYSARG_4);
		if (status < 0) return status;
		status = guest_path(tracee, first_guest,
			(int) peek_reg(tracee, CURRENT, SYSARG_1), first);
		if (status < 0) return status;
		status = guest_path(tracee, second_guest,
			(int) peek_reg(tracee, CURRENT, SYSARG_3), second);
		if (status < 0) return status;
		status = broker_call(ANDOCK_RENAME,
			sysnum == PR_renameat2
				? (int) peek_reg(tracee, CURRENT, SYSARG_5) : 0,
			0, first_guest, second_guest,
			NULL, 0, &response);
		if (status >= 0)
			update_open_file_paths(tracee, first_guest, response.path);
		free_response(&response, true);
		return status < 0 ? status : void_result(tracee, 0);
	case PR_symlink:
		status = get_sysarg_path(tracee, first, SYSARG_1);
		if (status < 0) return status;
		return mutation_path(tracee, ANDOCK_SYMLINK, AT_FDCWD, SYSARG_2,
			0, 0, first);
	case PR_symlinkat:
		status = get_sysarg_path(tracee, first, SYSARG_1);
		if (status < 0) return status;
		return mutation_path(tracee, ANDOCK_SYMLINK,
			(int) peek_reg(tracee, CURRENT, SYSARG_2), SYSARG_3,
			0, 0, first);
	default:
		return 0;
	}
}

static int logical_open_flags(int flags)
{
	int logical = flags & (O_ACCMODE | O_APPEND | O_NONBLOCK);
#ifdef O_DIRECT
	logical |= flags & O_DIRECT;
#endif
#ifdef O_DSYNC
	logical |= flags & O_DSYNC;
#endif
#ifdef O_LARGEFILE
	logical |= flags & O_LARGEFILE;
#endif
#ifdef O_NOATIME
	logical |= flags & O_NOATIME;
#endif
#ifdef O_PATH
	logical |= flags & O_PATH;
#endif
#ifdef O_SYNC
	logical |= flags & O_SYNC;
#endif
	return logical;
}

static struct AndockFileDescription *acquire_file_description(
		struct AndockFileDescription *shared, off_t offset, int flags)
{
	if (shared != NULL) {
		shared->references++;
		return shared;
	}
	struct AndockFileDescription *description = calloc(1, sizeof(*description));
	if (description == NULL)
		return NULL;
	description->offset = offset;
	description->flags = logical_open_flags(flags);
	description->references = 1;
	return description;
}

static void add_open_file_at_offset(Tracee *tracee, int fd, int host_fd,
		const char *path, uint64_t inode, uint64_t cache_id,
		off_t offset, int flags, nlink_t nlink, bool is_directory,
		struct AndockFileDescription *shared_description)
{
	struct AndockBrokerState *state = broker_state(tracee);
	struct AndockOpenFile *existing = find_open_file(tracee, fd);
	struct AndockOpenFile *file;
	struct AndockFileDescription *description;
	if (state == NULL || state->files == NULL) {
		if (host_fd >= 0)
			close(host_fd);
		return;
	}
	description = acquire_file_description(shared_description, offset, flags);
	if (description == NULL) {
		if (host_fd >= 0)
			close(host_fd);
		return;
	}
	if (existing != NULL) {
		uint64_t old_cache_id = existing->cache_id;
		char *copy = talloc_strdup(existing, path);
		if (copy == NULL) {
			release_file_description(description);
			if (host_fd >= 0)
				close(host_fd);
			return;
		}
		if (existing->host_fd >= 0)
			close(existing->host_fd);
		TALLOC_FREE(existing->path);
		existing->host_fd = host_fd;
		existing->path = copy;
		release_file_description(existing->description);
		existing->description = description;
		existing->inode = inode;
		existing->cache_id = cache_id;
		existing->nlink = nlink;
		existing->directory = is_directory;
		if (old_cache_id != cache_id) {
			if (old_cache_id != 0)
				andock_image_engine_release(old_cache_id);
			if (cache_id != 0)
				andock_image_engine_retain(cache_id);
		}
		return;
	}
	file = talloc_zero(state->files, struct AndockOpenFile);
	if (file == NULL) {
		release_file_description(description);
		if (host_fd >= 0)
			close(host_fd);
		return;
	}
	file->fd = fd;
	file->host_fd = host_fd;
	file->description = description;
	file->inode = inode;
	file->cache_id = cache_id;
	file->nlink = nlink;
	file->directory = is_directory;
	talloc_set_destructor(file, close_open_file);
	file->path = talloc_strdup(file, path);
	if (file->path == NULL) {
		TALLOC_FREE(file);
		return;
	}
	file->next = state->files->open_files;
	state->files->open_files = file;
	if (cache_id != 0)
		andock_image_engine_retain(cache_id);
}

static void add_open_file(Tracee *tracee, int fd, int host_fd,
		const char *path, uint64_t inode, uint64_t cache_id, nlink_t nlink,
		bool is_directory, int flags)
{
	add_open_file_at_offset(
		tracee, fd, host_fd, path, inode, cache_id, 0, flags,
		nlink, is_directory, NULL);
}

static void remove_open_file(Tracee *tracee, int fd)
{
	struct AndockBrokerState *state = broker_state(tracee);
	struct AndockOpenFile **cursor;
	if (state == NULL || state->files == NULL)
		return;
	cursor = &state->files->open_files;
	while (*cursor != NULL) {
		if ((*cursor)->fd == fd) {
			struct AndockOpenFile *removed = *cursor;
			*cursor = removed->next;
			TALLOC_FREE(removed);
			return;
		}
		cursor = &(*cursor)->next;
	}
}

static int handle_exit(Tracee *tracee)
{
	struct AndockBrokerState *state = broker_state(tracee);
	Sysnum sysnum = get_sysnum(tracee, ORIGINAL);
	int64_t syscall_result = (int64_t)peek_reg(
		tracee, CURRENT, SYSARG_RESULT);
	int result = (int)syscall_result;
	int status;
	struct AndockOpenFile *source = NULL;
	if (state != NULL && state->pending_offset_update) {
		if (syscall_result > 0) {
			struct AndockOpenFile *file = find_open_file(
				tracee, (int)peek_reg(tracee, ORIGINAL, SYSARG_1));
			if (file != NULL && file->description != NULL)
				file->description->offset =
					state->pending_offset + (off_t)syscall_result;
		}
		state->pending_offset_update = false;
	}
	if (state != NULL && state->transfer_pending) {
		if (syscall_result > 0) {
			struct AndockOpenFile *input = find_open_file(
				tracee, state->transfer_input_fd);
			struct AndockOpenFile *output = find_open_file(
				tracee, state->transfer_output_fd);
			if (state->transfer_update_input && input != NULL)
				input->description->offset = state->transfer_input_offset +
					(off_t)syscall_result;
			if (state->transfer_update_output && output != NULL)
				output->description->offset = state->transfer_output_offset +
					(off_t)syscall_result;
			if (state->transfer_output_cache_id != 0)
				andock_image_engine_mark_dirty(
					state->transfer_output_cache_id);
		}
		state->transfer_pending = false;
		state->transfer_output_cache_id = 0;
	}
	if (state != NULL && state->sendmsg_pending) {
		state->sendmsg_pending = false;
		status = write_data(
			tracee, state->sendmsg_header,
			&state->sendmsg_original, sizeof(state->sendmsg_original));
		if (status < 0)
			return status;
	}
	if (state != NULL && state->recvfrom_pending) {
		state->recvfrom_pending = false;
		if (result >= 0) {
			status = translate_socketcall_exit(
				tracee, state->recvfrom_address,
				state->recvfrom_size_address,
				state->recvfrom_max_size);
			if (status < 0)
				return status;
		}
	}
	if (state != NULL && state->recvmsg_pending) {
		state->recvmsg_pending = false;
		if (result >= 0) {
			status = translate_socketcall_exit(
				tracee, state->recvmsg_address,
				state->recvmsg_size_address,
				state->recvmsg_max_size);
			if (status < 0)
				return status;
		}
	}
	if (state != NULL && state->pending_path != NULL) {
		if (result >= 0) {
			if (state->pending_dirty && state->pending_cache_id != 0)
				andock_image_engine_mark_dirty(state->pending_cache_id);
			add_open_file(tracee, result, state->pending_host_fd,
				state->pending_path,
				state->pending_inode, state->pending_cache_id,
				state->pending_nlink,
				state->pending_is_directory, state->pending_flags);
		}
		else if (state->pending_host_fd >= 0)
			close(state->pending_host_fd);
		state->pending_host_fd = -1;
		release_pending_cache(state);
		TALLOC_FREE(state->pending_path);
	}
	if (result >= 0) {
		switch (sysnum) {
		case PR_dup:
			source = find_open_file(tracee,
				(int) peek_reg(tracee, ORIGINAL, SYSARG_1));
			break;
		case PR_dup2:
		case PR_dup3:
			if (result != (int)peek_reg(tracee, ORIGINAL, SYSARG_1)) {
				remove_open_file(tracee, result);
				source = find_open_file(tracee,
					(int)peek_reg(tracee, ORIGINAL, SYSARG_1));
			}
			break;
		case PR_fcntl:
		case PR_fcntl64:
			if ((int) peek_reg(tracee, ORIGINAL, SYSARG_2) == F_DUPFD
			    || (int) peek_reg(tracee, ORIGINAL, SYSARG_2) == F_DUPFD_CLOEXEC)
				source = find_open_file(tracee,
					(int) peek_reg(tracee, ORIGINAL, SYSARG_1));
			break;
		default:
			break;
		}
		if (source != NULL)
			add_open_file_at_offset(tracee, result,
				source->host_fd >= 0
					? fcntl(source->host_fd, F_DUPFD_CLOEXEC, 0) : -1,
				source->path, source->inode, source->cache_id,
				0, 0, source->nlink,
				source->directory, source->description);
	}
	if (sysnum == PR_close && result == 0)
		remove_open_file(tracee, (int) peek_reg(tracee, ORIGINAL, SYSARG_1));
	close_pending_fds(tracee);
	return 0;
}

static void inherit_open_files(Tracee *child, const Tracee *parent)
{
	struct AndockBrokerState *parent_state = broker_state((Tracee *) parent);
	struct AndockOpenFile *file =
		parent_state == NULL || parent_state->files == NULL
			? NULL : parent_state->files->open_files;
	while (file != NULL) {
		add_open_file_at_offset(child, file->fd,
			file->host_fd >= 0
				? fcntl(file->host_fd, F_DUPFD_CLOEXEC, 0) : -1,
			file->path, file->inode, file->cache_id, 0, 0,
			file->nlink, file->directory, file->description);
		file = file->next;
	}
}

int andock_image_callback(Extension *extension, ExtensionEvent event,
		intptr_t data1, intptr_t data2)
{
	Tracee *tracee;
	struct AndockBrokerState *state;
	int status;
	if (event == INITIALIZATION) {
		const char *value = getenv("ANDOCK_IMAGE_FD");
		char *end;
		long image_fd;
		if (!andock_image_enabled())
			return -ENOTCONN;
		errno = 0;
		image_fd = value == NULL ? -1 : strtol(value, &end, 10);
		if (value == NULL || errno != 0 || *value == '\0' || *end != '\0' ||
			image_fd < 0 || image_fd > INT_MAX) {
			dprintf(STDERR_FILENO,
				"andock: invalid ANDOCK_IMAGE_FD environment value\n");
			return -EBADF;
		}
		if (fcntl((int)image_fd, F_GETFD) < 0) {
			int error = errno;
			dprintf(STDERR_FILENO,
				"andock: member image descriptor %ld is unavailable: %s (%d)\n",
				image_fd, strerror(error), error);
			return -EBADF;
		}
		status = andock_image_engine_start((int)image_fd);
		close((int)image_fd);
		unsetenv("ANDOCK_IMAGE_FD");
		if (status < 0) {
			dprintf(STDERR_FILENO,
				"andock: member image initialization failed: %s (%d)\n",
				strerror(-status), status);
			return status;
		}
		extension->config = talloc_zero(extension, struct AndockBrokerState);
		if (extension->config == NULL) {
			andock_image_engine_stop();
			return -ENOMEM;
		}
		state = extension->config;
		state->host_socket_fd = -1;
		state->host_listener_fd = -1;
		state->tracee_channel_fd = -1;
		state->pending_host_fd = -1;
		state->files = talloc_zero(state, struct AndockFileTable);
		state->unix_sockets =
			talloc_zero(state, struct AndockUnixSocketTable);
		if (state->files == NULL || state->unix_sockets == NULL) {
			andock_image_engine_stop();
			return -ENOMEM;
		}
		extension->filtered_sysnums = filtered_sysnums;
		struct timespec now;
		clock_gettime(CLOCK_MONOTONIC, &now);
		image_instance_nonce = ((uint64_t)getpid() << 32) ^
			(uint64_t)now.tv_sec ^ (uint64_t)now.tv_nsec;
		image_active = true;
		image_extension_users = 1;
		return 0;
	}
	if (event == INHERIT_CHILD) {
		Extension *parent_extension = (Extension *) data1;
		struct AndockBrokerState *parent_state;
		extension->config = talloc_zero(extension, struct AndockBrokerState);
		if (extension->config == NULL)
			return -ENOMEM;
		state = extension->config;
		parent_state = parent_extension->config;
		state->host_socket_fd = -1;
		state->host_listener_fd = -1;
		state->tracee_channel_fd = -1;
		state->pending_host_fd = -1;
		state->unix_sockets =
			talloc_reference(state, parent_state->unix_sockets);
		if (((word_t) data2 & CLONE_FILES) != 0) {
			state->files = talloc_reference(state, parent_state->files);
		}
		else {
			state->files = talloc_zero(state, struct AndockFileTable);
			if (state->files != NULL)
				inherit_open_files(TRACEE(extension), TRACEE(parent_extension));
		}
		if (state->files == NULL || state->unix_sockets == NULL)
			return -ENOMEM;
		extension->filtered_sysnums = filtered_sysnums;
		image_extension_users++;
		return 0;
	}
	tracee = TRACEE(extension);
	state = extension->config;
	if (state == NULL)
		return event == REMOVED ? 0 : -ENOTCONN;
	switch (event) {
	case SYSCALL_ENTER_START:
		return handle_enter(extension, tracee);
	case SYSCALL_EXIT_START:
		if (state->socket_state != ANDOCK_SOCKET_IDLE)
			return handle_socket_chain(tracee, state);
		status = handle_exit(tracee);
		if (state->synthetic_result_valid) {
			poke_reg(tracee, SYSARG_RESULT, state->synthetic_result);
			state->synthetic_result_valid = false;
			return 1;
		}
		return status;
	case SYSCALL_CHAINED_EXIT:
		if (state->socket_state != ANDOCK_SOCKET_IDLE)
			handle_socket_chain(tracee, state);
		return 0;
	case INHERIT_PARENT:
		return 1;
	case REMOVED:
		close_socket_state(state);
		close_pending_fds(tracee);
		if (state->pending_host_fd >= 0) {
			close(state->pending_host_fd);
			state->pending_host_fd = -1;
		}
		release_pending_cache(state);
		if (image_extension_users > 0 && --image_extension_users == 0) {
			release_file_locks(NULL);
			andock_image_engine_stop();
			image_active = false;
		}
		return 0;
	default:
		return 0;
	}
}
