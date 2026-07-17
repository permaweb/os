#define _GNU_SOURCE

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>

#define ANDOCK_IMAGE_CAPABILITY 0x41

int andock_receive_image_fd(const char *name);

enum scenario {
	CAPABILITY_OK,
	CAPABILITY_MISSING,
	CAPABILITY_EXTRA,
	CAPABILITY_MALFORMED,
};

struct server {
	int listener;
	int fds[2];
	size_t fd_count;
	enum scenario scenario;
};

static int fd_count(void)
{
	DIR *directory = opendir("/proc/self/fd");
	struct dirent *entry;
	int count = -1;

	if (directory == NULL)
		return -1;
	while ((entry = readdir(directory)) != NULL) {
		if (strcmp(entry->d_name, ".") != 0 &&
			strcmp(entry->d_name, "..") != 0)
			count++;
	}
	closedir(directory);
	return count;
}

static void close_extra_fds(void)
{
	DIR *directory = opendir("/proc/self/fd");
	struct dirent *entry;
	int directory_fd;

	if (directory == NULL)
		_exit(1);
	directory_fd = dirfd(directory);
	while ((entry = readdir(directory)) != NULL) {
		char *end;
		long fd = strtol(entry->d_name, &end, 10);
		if (*end == '\0' && fd > 2 && fd != directory_fd)
			close((int)fd);
	}
	closedir(directory);
}

static int open_image(int flags)
{
	char path[] = "/tmp/andock-launcher-image-XXXXXX";
	int writable = mkstemp(path);
	int fd;

	if (writable < 0 || ftruncate(writable, 4096) < 0 ||
		pwrite(writable, "andock-image", 12, 0) != 12) {
		perror("create image");
		exit(1);
	}
	unlink(path);
	if ((flags & O_ACCMODE) == O_RDWR)
		fd = writable;
	else {
		char proc_path[64];
		snprintf(proc_path, sizeof(proc_path), "/proc/self/fd/%d", writable);
		fd = open(proc_path, flags | O_CLOEXEC);
		close(writable);
	}
	if (fd < 0 || fcntl(fd, F_SETFD, FD_CLOEXEC) < 0) {
		perror("open image");
		exit(1);
	}
	return fd;
}

static int listen_on_name(const char *name)
{
	struct sockaddr_un address = { .sun_family = AF_UNIX };
	size_t name_size;
	int listener;

	name_size = strlen(name);
	memcpy(address.sun_path + 1, name, name_size);
	listener = socket(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC, 0);
	if (listener < 0 || bind(listener, (struct sockaddr *)&address,
			offsetof(struct sockaddr_un, sun_path) + 1 + name_size) < 0 ||
		listen(listener, 1) < 0) {
		perror("listen");
		exit(1);
	}
	return listener;
}

static int open_listener(char name[64], unsigned int sequence)
{
	snprintf(name, 64, "andock-launcher-test-%d-%u", getpid(), sequence);
	return listen_on_name(name);
}

static int send_capability(int socket_fd, const int *fds, size_t fd_count,
	char payload)
{
	char control_buffer[CMSG_SPACE(sizeof(int) * 2)] = {};
	struct iovec vector = {
		.iov_base = &payload,
		.iov_len = sizeof(payload),
	};
	struct msghdr message = {
		.msg_iov = &vector,
		.msg_iovlen = 1,
	};

	if (fd_count > 0) {
		message.msg_control = control_buffer;
		message.msg_controllen = CMSG_SPACE(sizeof(int) * fd_count);
		struct cmsghdr *control = CMSG_FIRSTHDR(&message);
		control->cmsg_level = SOL_SOCKET;
		control->cmsg_type = SCM_RIGHTS;
		control->cmsg_len = CMSG_LEN(sizeof(int) * fd_count);
		memcpy(CMSG_DATA(control), fds, sizeof(int) * fd_count);
	}
	return sendmsg(socket_fd, &message, MSG_NOSIGNAL);
}

static void *serve(void *argument)
{
	struct server *server = argument;
	int client = accept4(server->listener, NULL, NULL, SOCK_CLOEXEC);
	char payload = server->scenario == CAPABILITY_MALFORMED
		? 0 : ANDOCK_IMAGE_CAPABILITY;

	if (client >= 0)
		send_capability(client, server->fds, server->fd_count, payload);
	if (client >= 0)
		close(client);
	close(server->listener);
	return NULL;
}

static void check_case(enum scenario scenario, int source_fd,
	int second_fd, int expected)
{
	static unsigned int sequence;
	char name[64];
	struct server server = {
		.listener = open_listener(name, ++sequence),
		.fds = { source_fd, second_fd },
		.fd_count = scenario == CAPABILITY_MISSING ? 0 :
			(scenario == CAPABILITY_EXTRA ? 2 : 1),
		.scenario = scenario,
	};
	int baseline = fd_count() - 2 - (second_fd >= 0 ? 1 : 0);
	pthread_t thread;

	if (pthread_create(&thread, NULL, serve, &server) != 0) {
		perror("pthread_create");
		exit(1);
	}
	int image_fd = andock_receive_image_fd(name);
	pthread_join(thread, NULL);
	close(source_fd);
	if (second_fd >= 0)
		close(second_fd);
	if (expected == 0) {
		char content[12];
		if (image_fd < 0 || pread(image_fd, content, sizeof(content), 0) != 12 ||
			memcmp(content, "andock-image", 12) != 0 ||
			(fcntl(image_fd, F_GETFD) & FD_CLOEXEC) == 0 ||
			fd_count() != baseline + 1) {
			fprintf(stderr, "valid capability did not yield exactly one fd\n");
			exit(1);
		}
		close(image_fd);
	}
	else if (image_fd != expected) {
		fprintf(stderr, "capability error: got %d expected %d\n",
			image_fd, expected);
		exit(1);
	}
	if (fd_count() != baseline) {
		fprintf(stderr, "capability path leaked a descriptor\n");
		exit(1);
	}
}

static int probe_image_fd(void)
{
	const char *value = getenv("ANDOCK_IMAGE_FD");
	const char *network_value = getenv("ANDOCK_NETWORK_FD");
	char *end;
	char content[12];
	long image_fd;
	long network_fd = -1;
	DIR *directory;
	struct dirent *entry;

	if (value == NULL)
		return 1;
	errno = 0;
	image_fd = strtol(value, &end, 10);
	if (errno != 0 || *end != '\0' || image_fd < 0 || image_fd > INT32_MAX ||
		fcntl((int)image_fd, F_GETFD) != 0 ||
		pread((int)image_fd, content, sizeof(content), 0) != 12 ||
		memcmp(content, "andock-image", 12) != 0)
		return 1;
	if (network_value != NULL) {
		int socket_type;
		socklen_t socket_type_size = sizeof(socket_type);
		errno = 0;
		network_fd = strtol(network_value, &end, 10);
		if (errno != 0 || *end != '\0' || network_fd < 0
		    || network_fd > INT32_MAX
		    || fcntl((int) network_fd, F_GETFD) != 0
		    || getsockopt((int) network_fd, SOL_SOCKET, SO_TYPE,
			&socket_type, &socket_type_size) < 0
		    || socket_type != SOCK_SEQPACKET)
			return 1;
	}
	directory = opendir("/proc/self/fd");
	if (directory == NULL)
		return 1;
	while ((entry = readdir(directory)) != NULL) {
		char fd_path[64];
		char target[256];
		char *parse_end;
		long fd;
		ssize_t length;

		if (entry->d_name[0] == '.')
			continue;
		fd = strtol(entry->d_name, &parse_end, 10);
		if (*parse_end != '\0' || fd <= 2 || fd == image_fd
		    || fd == network_fd ||
			fd == dirfd(directory))
			continue;
		snprintf(fd_path, sizeof(fd_path), "/proc/self/fd/%ld", fd);
		length = readlink(fd_path, target, sizeof(target) - 1);
		if (length >= 0) {
			target[length] = '\0';
			if (strncmp(target, "socket:[", 8) == 0) {
				fprintf(stderr, "capability socket leaked as fd %ld\n", fd);
				closedir(directory);
				return 1;
			}
		}
	}
	closedir(directory);
	return 0;
}

static void check_exec(const char *launcher, const char *test_program,
		bool with_network)
{
	char image_name[64];
	char network_name[64];
	int listener = open_listener(image_name, with_network ? 1001 : 1000);
	int network_listener = with_network
		? open_listener(network_name, 1002) : -1;
	int source_fd = open_image(O_RDWR);
	pid_t child = fork();
	int status;
	int network_client = -1;

	if (child < 0) {
		perror("fork");
		exit(1);
	}
	if (child == 0) {
		close_extra_fds();
		if (with_network)
			execl(launcher, launcher, "--socket", image_name,
				"--network-socket", network_name, "--",
				test_program, "--probe", NULL);
		else
			execl(launcher, launcher, "--socket", image_name, "--",
				test_program, "--probe", NULL);
		_exit(127);
	}
	int client = accept4(listener, NULL, NULL, SOCK_CLOEXEC);
	if (client < 0 || send_capability(client, &source_fd, 1,
			ANDOCK_IMAGE_CAPABILITY) != 1) {
		perror("send exec capability");
		exit(1);
	}
	close(client);
	close(listener);
	close(source_fd);
	if (with_network) {
		network_client = accept4(
			network_listener, NULL, NULL, SOCK_CLOEXEC);
		close(network_listener);
		if (network_client < 0) {
			perror("accept network capability");
			exit(1);
		}
	}
	if (waitpid(child, &status, 0) != child || !WIFEXITED(status) ||
		WEXITSTATUS(status) != 0) {
		fprintf(stderr, "launcher exec path failed\n");
		exit(1);
	}
	if (network_client >= 0)
		close(network_client);
}

static void check_wrong_uid(void)
{
	char name[64];
	char ready;
	int readiness[2];
	int source_fd;
	int baseline = fd_count();
	int status;
	pid_t child;

	if (geteuid() != 0) {
		fprintf(stderr, "wrong-UID capability test requires root\n");
		exit(1);
	}
	snprintf(name, sizeof(name), "andock-launcher-test-%d-wrong-uid", getpid());
	if (pipe2(readiness, O_CLOEXEC) != 0) {
		perror("pipe2");
		exit(1);
	}
	source_fd = open_image(O_RDWR);
	child = fork();
	if (child < 0) {
		perror("fork");
		exit(1);
	}
	if (child == 0) {
		close(readiness[0]);
		if (setuid(65534) != 0)
			_exit(1);
		int listener = listen_on_name(name);
		if (write(readiness[1], "r", 1) != 1)
			_exit(1);
		close(readiness[1]);
		int client = accept4(listener, NULL, NULL, SOCK_CLOEXEC);
		if (client >= 0)
			send_capability(client, &source_fd, 1,
				ANDOCK_IMAGE_CAPABILITY);
		if (client >= 0)
			close(client);
		close(listener);
		close(source_fd);
		_exit(0);
	}
	close(readiness[1]);
	close(source_fd);
	if (read(readiness[0], &ready, 1) != 1) {
		fprintf(stderr, "wrong-UID server did not start\n");
		exit(1);
	}
	close(readiness[0]);
	if (andock_receive_image_fd(name) != -EPERM) {
		fprintf(stderr, "wrong-UID image capability was accepted\n");
		exit(1);
	}
	if (waitpid(child, &status, 0) != child || !WIFEXITED(status) ||
		WEXITSTATUS(status) != 0 || fd_count() != baseline) {
		fprintf(stderr, "wrong-UID rejection leaked a descriptor\n");
		exit(1);
	}
}

int main(int argc, char **argv)
{
	int pipe_fds[2];

	if (argc == 2 && strcmp(argv[1], "--probe") == 0)
		return probe_image_fd();
	if (argc != 2) {
		fprintf(stderr, "usage: %s LAUNCHER\n", argv[0]);
		return 2;
	}
	check_case(CAPABILITY_OK, open_image(O_RDWR), -1, 0);
	check_case(CAPABILITY_MISSING, open_image(O_RDWR), -1, -EPROTO);
	int first = open_image(O_RDWR);
	check_case(CAPABILITY_EXTRA, first, dup(first), -EPROTO);
	check_case(CAPABILITY_MALFORMED, open_image(O_RDWR), -1, -EPROTO);
	check_case(CAPABILITY_OK, open_image(O_RDONLY), -1, -EINVAL);
	if (pipe2(pipe_fds, O_CLOEXEC) != 0) {
		perror("pipe2");
		return 1;
	}
	close(pipe_fds[1]);
	check_case(CAPABILITY_OK, pipe_fds[0], -1, -EINVAL);
	check_wrong_uid();
	check_exec(argv[1], argv[0], false);
	check_exec(argv[1], argv[0], true);
	puts("ANDOCK_PROOT_LAUNCHER_TEST_OK");
	return 0;
}
