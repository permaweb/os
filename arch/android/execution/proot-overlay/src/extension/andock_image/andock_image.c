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
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/file.h>
#include <sys/mman.h>
#include <sys/vfs.h>
#include <sys/xattr.h>
#include <sys/un.h>
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
	char *path;
	uint8_t *data;
	size_t data_size;
	int fd;
	int backing_fd;
};

struct AndockOpenFile {
	int fd;
	int host_fd;
	size_t offset;
	nlink_t nlink;
	uint64_t inode;
	char *path;
	bool directory;
	bool dirty;
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

static int close_open_file(struct AndockOpenFile *file)
{
	if (file->inode != 0 && image_active)
		andock_image_engine_release(file->inode);
	if (file->host_fd >= 0)
		close(file->host_fd);
	return 0;
}

enum AndockSocketState {
	ANDOCK_SOCKET_IDLE,
	ANDOCK_SOCKET_CREATED,
	ANDOCK_SOCKET_CONNECTED,
	ANDOCK_SOCKET_RECEIVING,
};

static void add_open_file(Tracee *tracee, int fd, int host_fd,
	const char *path, uint64_t inode, nlink_t nlink, bool is_directory);

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
	bool pending_is_directory;
	int pending_host_fd;
	bool pending_dirty;
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

struct AndockRecvMsgPointers {
	word_t msghdr;
	word_t control;
};

static unsigned int image_extension_users;
static uint64_t image_instance_nonce;
static uint64_t transfer_sequence;

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
		close(duplicate);
		errno = error;
		return -1;
	}
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
	TALLOC_FREE(state->pending_path);
	close_socket_state(state);
	return 1;
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

static struct AndockOpenFile *find_proc_open_file(Tracee *tracee,
		const char *path)
{
	static const char *prefixes[] = {
		"/proc/self/fd/",
		"/proc/thread-self/fd/",
		NULL,
	};
	char pid_prefix[64];
	const char *number = NULL;
	char *end;
	long fd;
	int index;

	for (index = 0; prefixes[index] != NULL; index++) {
		size_t length = strlen(prefixes[index]);
		if (strncmp(path, prefixes[index], length) == 0) {
			number = path + length;
			break;
		}
	}
	if (number == NULL) {
		int length = snprintf(pid_prefix, sizeof(pid_prefix),
			"/proc/%d/fd/", tracee->pid);
		if (length < 0 || (size_t) length >= sizeof(pid_prefix)
		    || strncmp(path, pid_prefix, (size_t) length) != 0)
			return NULL;
		number = path + length;
	}
	if (*number == '\0')
		return NULL;
	errno = 0;
	fd = strtol(number, &end, 10);
	if (errno != 0 || *end != '\0' || fd < 0 || fd > INT_MAX)
		return NULL;
	return find_open_file(tracee, (int) fd);
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
	static const char *devices[] = {
		"/dev/null", "/dev/zero", "/dev/full", "/dev/random",
		"/dev/urandom", "/dev/stdin", "/dev/stdout", "/dev/stderr",
		"/dev/ptmx",
		NULL,
	};
	int index;

	if (strcmp(path, "/proc/self") == 0
	    || strncmp(path, "/proc/self/", strlen("/proc/self/")) == 0
	    || strcmp(path, "/proc/thread-self") == 0
	    || strncmp(path, "/proc/thread-self/",
		strlen("/proc/thread-self/")) == 0)
		return true;
	if (strcmp(path, "/dev/pts") == 0
	    || strncmp(path, "/dev/pts/", strlen("/dev/pts/")) == 0
	    || strcmp(path, "/dev/fd") == 0
	    || strncmp(path, "/dev/fd/", strlen("/dev/fd/")) == 0
	    || strcmp(path, "/sys/devices/system/cpu") == 0
	    || strncmp(path, "/sys/devices/system/cpu/",
		strlen("/sys/devices/system/cpu/")) == 0)
		return true;
	for (index = 0; devices[index] != NULL; index++) {
		if (strcmp(path, devices[index]) == 0)
			return true;
	}
	return false;
}

static int guest_path(Tracee *tracee, char result[PATH_MAX], int dir_fd,
		const char *user_path)
{
	const char *base;
	struct AndockOpenFile *directory;

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
		if (strlen(user_path) >= PATH_MAX)
			return -ENAMETOOLONG;
		strcpy(result, user_path);
		return 0;
	}
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
	return translate_path_with_policy(tracee, result, dir_fd, user_path,
		deref_final, true);
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
	if (command == NULL)
		command = "/bin/sh";
	if (strchr(command, '/') != NULL)
		return resolve_executable(tracee, result, command);

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
		uint64_t inode, nlink_t nlink, bool directory)
{
	struct AndockBrokerState *state = broker_state(tracee);
	if (state == NULL)
		return -ENOTCONN;
	TALLOC_FREE(state->pending_path);
	state->pending_path = talloc_strdup(state, path);
	if (state->pending_path == NULL)
		return -ENOMEM;
	state->pending_nlink = nlink;
	state->pending_inode = inode;
	state->pending_is_directory = directory;
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
			tracee, resolved.path, resolved.inode, 2, true);
		free_response(&resolved, true);
		if (status < 0)
			return status;
		return set_sysarg_path(tracee, "/system", reg);
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
		response_nlink(&opened), false);
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
	if (path[0] == '/' && andock_image_is_kernel_path(path))
		return 0;
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

static int void_result(Tracee *tracee, int result)
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

static int flush_open_file(struct AndockOpenFile *file)
{
	if (file == NULL || file->inode == 0)
		return 0;
	return andock_image_engine_sync(file->inode);
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
			andock_image_engine_mark_dirty(file->inode);
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
		andock_image_engine_mark_dirty(file->inode);
	return 0;
}

static int handle_statfs(Tracee *tracee, Sysnum sysnum)
{
	char path[PATH_MAX];
	char guest[PATH_MAX];
	struct AndockResponse response = { .fd = -1, .backing_fd = -1 };
	struct statfs output = {};
	uint64_t fields[8];
	int status;
	int index;

	if (sysnum != PR_statfs)
		return 0;
	status = get_sysarg_path(tracee, path, SYSARG_1);
	if (status < 0)
		return status;
	status = guest_path(tracee, guest, AT_FDCWD, path);
	if (status < 0)
		return status;
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
	output.f_type = 0x794c7630; /* Linux overlayfs magic. */
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
	if (path[0] == '/' && andock_image_is_kernel_path(path))
		return 0;
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
		if (path[0] == '/' && andock_image_is_kernel_path(path))
			return 0;
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
	struct flock lock = {
		.l_whence = SEEK_SET,
		.l_start = 0,
		.l_len = 0,
	};
	word_t address;
	int operation;
	int type;
	int status;

	if (sysnum != PR_flock)
		return 0;
	operation = (int) peek_reg(tracee, CURRENT, SYSARG_2);
	if ((operation & ~(LOCK_SH | LOCK_EX | LOCK_UN | LOCK_NB)) != 0)
		return -EINVAL;
	type = operation & (LOCK_SH | LOCK_EX | LOCK_UN);
	if (type != LOCK_SH && type != LOCK_EX && type != LOCK_UN)
		return -EINVAL;
	lock.l_type = type == LOCK_SH ? F_RDLCK
		: type == LOCK_EX ? F_WRLCK : F_UNLCK;
	address = (peek_reg(tracee, CURRENT, STACK_POINTER) - sizeof(lock))
		& ~(word_t) 15;
	status = write_data(tracee, address, &lock, sizeof(lock));
	if (status < 0)
		return status;
	set_sysnum(tracee, PR_fcntl);
	poke_reg(tracee, SYSARG_2,
		(operation & LOCK_NB) != 0 || type == LOCK_UN ? F_SETLK : F_SETLKW);
	poke_reg(tracee, SYSARG_3, address);
	poke_reg(tracee, SYSARG_4, 0);
	poke_reg(tracee, SYSARG_5, 0);
	poke_reg(tracee, SYSARG_6, 0);
	return 1;
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

static int resolve_stat_path(Tracee *tracee, struct AndockResponse *response,
		int dir_fd, Reg path_reg, int flags)
{
	struct AndockOpenFile *file;
	struct stat metadata;
	char path[PATH_MAX];
	int status = get_sysarg_path(tracee, path, path_reg);
	if (status < 0)
		return status;
	if (path[0] == '/' && andock_image_is_kernel_path(path))
		return 1;
	if (path[0] != '\0')
		return resolve(tracee, response, dir_fd, path,
			(flags & AT_SYMLINK_NOFOLLOW) == 0, false);
	if ((flags & AT_EMPTY_PATH) == 0)
		return -ENOENT;
	file = find_open_file(tracee, dir_fd);
	if (file == NULL)
		return 1;
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
		status = resolve(tracee, &response, AT_FDCWD, file->path, true, false);
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
	status = resolve(tracee, &response, AT_FDCWD, path, true, false);
	if (status < 0)
		return status;
	if (response.type != ANDOCK_DIRECTORY) {
		free_response(&response, true);
		return -ENOTDIR;
	}
	TALLOC_FREE(tracee->fs->cwd);
	tracee->fs->cwd = talloc_strdup(tracee->fs, response.path);
	free_response(&response, true);
	return tracee->fs->cwd != NULL ? void_result(tracee, 0) : -ENOMEM;
}

static int handle_directory_lseek(Tracee *tracee, Sysnum sysnum)
{
	struct AndockOpenFile *directory;
	int64_t offset;
	int whence;

	if (sysnum != PR_lseek)
		return 0;
	directory = find_directory(tracee,
		(int) peek_reg(tracee, CURRENT, SYSARG_1));
	if (directory == NULL)
		return 0;
	offset = (int64_t) peek_reg(tracee, CURRENT, SYSARG_2);
	whence = (int) peek_reg(tracee, CURRENT, SYSARG_3);
	if (whence == SEEK_CUR)
		offset += directory->offset;
	else if (whence != SEEK_SET)
		return -EINVAL;
	if (offset < 0)
		return -EINVAL;
	directory->offset = offset;
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
	if (path[0] == '/' && andock_image_is_kernel_path(path))
		return 0;
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
	struct AndockOpenFile *file;
	int status = get_sysarg_path(tracee, path, path_reg);
	if (status < 0)
		return status;
	if (size == 0)
		return -EINVAL;
	file = find_proc_open_file(tracee, path);
	if (file != NULL) {
		size_t length = strlen(file->path);
		if (size > length)
			size = length;
		status = write_data(tracee,
			peek_reg(tracee, CURRENT, buffer_reg), file->path, size);
		return status < 0 ? status : void_result(tracee, size);
	}
	if (path[0] == '/' && andock_image_is_kernel_path(path))
		return 0;
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
	output = calloc(1, output_size);
	if (output == NULL)
		return -ENOMEM;
	status = broker_call(ANDOCK_LIST, 0, 0, directory->path, NULL, NULL, 0, &response);
	if (status < 0) {
		free(output);
		return status;
	}
	if (directory->offset <= logical) {
		status = emit_dirent(output, output_size, &used, ".", 1,
			ANDOCK_DIRECTORY, logical++);
		if (status < 0)
			goto done;
	}
	else logical++;
	if (directory->offset <= logical) {
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
		if (directory->offset <= logical) {
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
	directory->offset += used == 0 ? 0 : logical - directory->offset;
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
			state->pending_host_fd = -1;
			add_open_file(tracee, (int) received_fd, host_fd,
				state->pending_path, state->pending_inode,
				state->pending_nlink,
				state->pending_is_directory);
			struct AndockOpenFile *file = find_open_file(
				tracee, (int)received_fd);
			if (file != NULL)
				file->dirty = state->pending_dirty;
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
	status = track_file_mutation(tracee, sysnum);
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
	status = handle_directory_lseek(tracee, sysnum);
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

static void add_open_file_at_offset(Tracee *tracee, int fd, int host_fd,
		const char *path, uint64_t inode, size_t offset,
		nlink_t nlink, bool is_directory)
{
	struct AndockBrokerState *state = broker_state(tracee);
	struct AndockOpenFile *existing = find_open_file(tracee, fd);
	struct AndockOpenFile *file;
	if (state == NULL || state->files == NULL) {
		if (host_fd >= 0)
			close(host_fd);
		return;
	}
	if (existing != NULL) {
		uint64_t old_inode = existing->inode;
		char *copy = talloc_strdup(existing, path);
		if (copy == NULL) {
			if (host_fd >= 0)
				close(host_fd);
			return;
		}
		if (existing->host_fd >= 0)
			close(existing->host_fd);
		TALLOC_FREE(existing->path);
		existing->host_fd = host_fd;
		existing->path = copy;
		existing->offset = offset;
		existing->inode = inode;
		existing->nlink = nlink;
		existing->directory = is_directory;
		existing->dirty = host_fd >= 0;
		if (old_inode != inode) {
			if (old_inode != 0)
				andock_image_engine_release(old_inode);
			if (inode != 0)
				andock_image_engine_retain(inode);
		}
		return;
	}
	file = talloc_zero(state->files, struct AndockOpenFile);
	if (file == NULL) {
		if (host_fd >= 0)
			close(host_fd);
		return;
	}
	file->fd = fd;
	file->host_fd = host_fd;
	file->offset = offset;
	file->inode = inode;
	file->nlink = nlink;
	file->directory = is_directory;
	file->dirty = host_fd >= 0;
	talloc_set_destructor(file, close_open_file);
	file->path = talloc_strdup(file, path);
	if (file->path == NULL) {
		TALLOC_FREE(file);
		return;
	}
	file->next = state->files->open_files;
	state->files->open_files = file;
	if (inode != 0)
		andock_image_engine_retain(inode);
}

static void add_open_file(Tracee *tracee, int fd, int host_fd,
		const char *path, uint64_t inode, nlink_t nlink, bool is_directory)
{
	add_open_file_at_offset(
		tracee, fd, host_fd, path, inode, 0, nlink, is_directory);
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
	int result = (int) peek_reg(tracee, CURRENT, SYSARG_RESULT);
	int status;
	struct AndockOpenFile *source = NULL;
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
		if (result >= 0)
			add_open_file(tracee, result, state->pending_host_fd,
				state->pending_path,
				state->pending_inode, state->pending_nlink,
				state->pending_is_directory);
		else if (state->pending_host_fd >= 0)
			close(state->pending_host_fd);
		state->pending_host_fd = -1;
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
			remove_open_file(tracee, result);
			source = find_open_file(tracee,
				(int) peek_reg(tracee, ORIGINAL, SYSARG_1));
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
				source->path, source->inode, source->offset, source->nlink,
				source->directory);
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
			file->path, file->inode, file->offset,
			file->nlink, file->directory);
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
			image_fd < 0 || image_fd > INT_MAX ||
			fcntl((int)image_fd, F_GETFD) < 0)
			return -EBADF;
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
		if (image_extension_users > 0 && --image_extension_users == 0) {
			andock_image_engine_stop();
			image_active = false;
		}
		return 0;
	default:
		return 0;
	}
}
