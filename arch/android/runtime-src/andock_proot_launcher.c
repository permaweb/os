#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/un.h>
#include <unistd.h>

#define ANDOCK_IMAGE_CAPABILITY 0x41
#define ANDOCK_MAX_CAPABILITY_FDS 8

int andock_connect_capability(const char *name)
{
	struct sockaddr_un address = { .sun_family = AF_UNIX };
	struct ucred peer;
	socklen_t peer_size = sizeof(peer);
	size_t name_size;
	int socket_fd;

	if (name == NULL || *name == '\0')
		return -EINVAL;
	name_size = strlen(name);
	if (name_size > sizeof(address.sun_path) - 1)
		return -ENAMETOOLONG;
	memcpy(address.sun_path + 1, name, name_size);
	socket_fd = socket(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC, 0);
	if (socket_fd < 0)
		return -errno;
	if (connect(socket_fd, (struct sockaddr *)&address,
			offsetof(struct sockaddr_un, sun_path) + 1 + name_size) < 0
	    || getsockopt(socket_fd, SOL_SOCKET, SO_PEERCRED,
			&peer, &peer_size) < 0) {
		int error = errno;
		close(socket_fd);
		return -error;
	}
	if (peer_size != sizeof(peer) || peer.uid != getuid()) {
		close(socket_fd);
		return -EPERM;
	}
	return socket_fd;
}

static void close_capability_fds(struct msghdr *message)
{
	struct cmsghdr *control;

	for (control = CMSG_FIRSTHDR(message); control != NULL;
		control = CMSG_NXTHDR(message, control)) {
		if (control->cmsg_level == SOL_SOCKET &&
			control->cmsg_type == SCM_RIGHTS &&
			control->cmsg_len >= CMSG_LEN(0)) {
			size_t bytes = control->cmsg_len - CMSG_LEN(0);
			int *fds = (int *)CMSG_DATA(control);
			for (size_t index = 0; index < bytes / sizeof(*fds); index++)
				close(fds[index]);
		}
	}
}

int andock_receive_image_fd(const char *name)
{
	char payload = 0;
	struct iovec vector = {
		.iov_base = &payload,
		.iov_len = sizeof(payload),
	};
	char control_buffer[CMSG_SPACE(
		sizeof(int) * ANDOCK_MAX_CAPABILITY_FDS)] = {};
	struct msghdr message = {
		.msg_iov = &vector,
		.msg_iovlen = 1,
		.msg_control = control_buffer,
		.msg_controllen = sizeof(control_buffer),
	};
	struct cmsghdr *control;
	struct stat status;
	int socket_fd = -1;
	int image_fd = -1;
	int image_fd_count = 0;
	int error = 0;
	bool malformed_control = false;

	socket_fd = andock_connect_capability(name);
	if (socket_fd < 0)
		return socket_fd;

	ssize_t received;
	do {
		received = recvmsg(socket_fd, &message, MSG_CMSG_CLOEXEC);
	} while (received < 0 && errno == EINTR);
	if (received < 0) {
		error = errno;
		goto fail;
	}
	for (control = CMSG_FIRSTHDR(&message); control != NULL;
		control = CMSG_NXTHDR(&message, control)) {
		if (control->cmsg_level != SOL_SOCKET ||
			control->cmsg_type != SCM_RIGHTS ||
			control->cmsg_len < CMSG_LEN(0)) {
			malformed_control = true;
			continue;
		}
		size_t bytes = control->cmsg_len - CMSG_LEN(0);
		if (bytes % sizeof(int) != 0) {
			malformed_control = true;
			continue;
		}
		int *fds = (int *)CMSG_DATA(control);
		for (size_t index = 0; index < bytes / sizeof(*fds); index++) {
			image_fd_count++;
			if (image_fd < 0)
				image_fd = fds[index];
			else
				close(fds[index]);
		}
	}
	if (received != 1 || payload != ANDOCK_IMAGE_CAPABILITY ||
		(message.msg_flags & (MSG_CTRUNC | MSG_TRUNC)) != 0 ||
		malformed_control || image_fd_count != 1) {
		error = EPROTO;
		goto fail;
	}
	if (fstat(image_fd, &status) < 0) {
		error = errno;
		goto fail;
	}
	if (!S_ISREG(status.st_mode) || status.st_size < 1024 ||
		(fcntl(image_fd, F_GETFL) & O_ACCMODE) != O_RDWR) {
		error = EINVAL;
		goto fail;
	}
	close(socket_fd);
	return image_fd;

fail:
	if (image_fd >= 0)
		close(image_fd);
	else
		close_capability_fds(&message);
	close(socket_fd);
	return -error;
}

#ifndef ANDOCK_PROOT_LAUNCHER_NO_MAIN
static int usage(const char *program)
{
	fprintf(stderr, "usage: %s --socket NAME [--network-socket NAME] "
		"-- PROOT [ARG ...]\n", program);
	return 64;
}

int main(int argc, char **argv)
{
	char image_fd_value[32];
	char network_fd_value[32];
	const char *network_name = NULL;
	int command_index;
	int flags;
	int image_fd;
	int network_fd = -1;

	if (argc < 5 || strcmp(argv[1], "--socket") != 0)
		return usage(argv[0]);
	if (strcmp(argv[3], "--") == 0)
		command_index = 4;
	else if (argc >= 7 && strcmp(argv[3], "--network-socket") == 0
		 && strcmp(argv[5], "--") == 0) {
		network_name = argv[4];
		command_index = 6;
	}
	else
		return usage(argv[0]);
	image_fd = andock_receive_image_fd(argv[2]);
	if (image_fd < 0) {
		fprintf(stderr, "andock: cannot receive member image: %s (%d)\n",
			strerror(-image_fd), image_fd);
		return 74;
	}
	if (network_name != NULL) {
		network_fd = andock_connect_capability(network_name);
		if (network_fd < 0) {
			close(image_fd);
			fprintf(stderr, "andock: cannot receive network capability: %s (%d)\n",
				strerror(-network_fd), network_fd);
			return 74;
		}
		flags = fcntl(network_fd, F_GETFD);
		if (flags < 0
		    || fcntl(network_fd, F_SETFD, flags & ~FD_CLOEXEC) < 0
		    || snprintf(network_fd_value, sizeof(network_fd_value),
			"%d", network_fd) < 0
		    || setenv("ANDOCK_NETWORK_FD", network_fd_value, 1) < 0) {
			int error = errno;
			close(network_fd);
			close(image_fd);
			fprintf(stderr, "andock: cannot prepare network capability: %s (%d)\n",
				strerror(error), -error);
			return 74;
		}
	}
	flags = fcntl(image_fd, F_GETFD);
	if (flags < 0 || fcntl(image_fd, F_SETFD, flags & ~FD_CLOEXEC) < 0) {
		int error = errno;
		unsetenv("ANDOCK_NETWORK_FD");
		if (network_fd >= 0)
			close(network_fd);
		close(image_fd);
		fprintf(stderr, "andock: cannot prepare member image: %s (%d)\n",
			strerror(error), -error);
		return 74;
	}
	if (snprintf(image_fd_value, sizeof(image_fd_value), "%d", image_fd) < 0 ||
		setenv("ANDOCK_IMAGE_FD", image_fd_value, 1) < 0) {
		int error = errno;
		unsetenv("ANDOCK_NETWORK_FD");
		if (network_fd >= 0)
			close(network_fd);
		close(image_fd);
		fprintf(stderr, "andock: cannot export member image: %s (%d)\n",
			strerror(error), -error);
		return 74;
	}
	execv(argv[command_index], &argv[command_index]);
	int error = errno;
	unsetenv("ANDOCK_NETWORK_FD");
	unsetenv("ANDOCK_IMAGE_FD");
	if (network_fd >= 0)
		close(network_fd);
	close(image_fd);
	fprintf(stderr, "andock: cannot execute %s: %s (%d)\n",
		argv[command_index], strerror(error), -error);
	return error == ENOENT ? 127 : 126;
}
#endif
