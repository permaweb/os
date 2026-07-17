#define _GNU_SOURCE

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>

#include "extension/andock_image/andock_network.h"

#define ANDOCK_NETWORK_MAGIC 0x414e4431U
#define ANDOCK_NETWORK_VERSION 1
#define ANDOCK_NETWORK_RESPONSE 0x80
#define ANDOCK_NETWORK_CREATE_SOCKET 1
#define ANDOCK_NETWORK_AUTHORIZE_DESTINATION 2
#define ANDOCK_NETWORK_HEADER_SIZE 16
#define ANDOCK_NETWORK_MAX_PACKET_SIZE 64
#define ANDOCK_NETWORK_MAX_CAPABILITY_FDS 8

static int capability_fd = -1;
static uint32_t request_id;

static void put_u16(uint8_t *output, uint16_t value)
{
	value = htons(value);
	memcpy(output, &value, sizeof(value));
}

static void put_u32(uint8_t *output, uint32_t value)
{
	value = htonl(value);
	memcpy(output, &value, sizeof(value));
}

static uint16_t get_u16(const uint8_t *input)
{
	uint16_t value;
	memcpy(&value, input, sizeof(value));
	return ntohs(value);
}

static uint32_t get_u32(const uint8_t *input)
{
	uint32_t value;
	memcpy(&value, input, sizeof(value));
	return ntohl(value);
}

static void close_received_fds(struct msghdr *message)
{
	struct cmsghdr *control;

	for (control = CMSG_FIRSTHDR(message); control != NULL;
		control = CMSG_NXTHDR(message, control)) {
		if (control->cmsg_level == SOL_SOCKET
		    && control->cmsg_type == SCM_RIGHTS
		    && control->cmsg_len >= CMSG_LEN(0)) {
			size_t bytes = control->cmsg_len - CMSG_LEN(0);
			int *fds = (int *) CMSG_DATA(control);
			for (size_t index = 0; index < bytes / sizeof(*fds); index++)
				close(fds[index]);
		}
	}
}

static int call(uint8_t opcode, const uint8_t *payload, size_t payload_size,
		int *received_fd)
{
	uint8_t request[ANDOCK_NETWORK_MAX_PACKET_SIZE] = {};
	uint8_t response[ANDOCK_NETWORK_MAX_PACKET_SIZE + 1] = {};
	char control_buffer[CMSG_SPACE(
		sizeof(int) * ANDOCK_NETWORK_MAX_CAPABILITY_FDS)] = {};
	struct iovec vector = { .iov_base = response, .iov_len = sizeof(response) };
	struct msghdr message = {
		.msg_iov = &vector,
		.msg_iovlen = 1,
		.msg_control = control_buffer,
		.msg_controllen = sizeof(control_buffer),
	};
	struct cmsghdr *control;
	ssize_t result;
	uint32_t id;
	int descriptor = -1;
	int descriptors = 0;
	bool malformed_control = false;

	if (received_fd != NULL)
		*received_fd = -1;
	if (capability_fd < 0)
		return -EACCES;
	if (payload_size > sizeof(request) - ANDOCK_NETWORK_HEADER_SIZE)
		return -EMSGSIZE;
	if (request_id == UINT32_MAX)
		return -EOVERFLOW;
	id = ++request_id;
	put_u32(request, ANDOCK_NETWORK_MAGIC);
	request[4] = ANDOCK_NETWORK_VERSION;
	request[5] = opcode;
	put_u16(request + 6, 0);
	put_u32(request + 8, id);
	put_u32(request + 12, (uint32_t) payload_size);
	memcpy(request + ANDOCK_NETWORK_HEADER_SIZE, payload, payload_size);
	do {
		result = send(capability_fd, request,
			ANDOCK_NETWORK_HEADER_SIZE + payload_size, MSG_NOSIGNAL);
	} while (result < 0 && errno == EINTR);
	if (result < 0)
		return -errno;
	if ((size_t) result != ANDOCK_NETWORK_HEADER_SIZE + payload_size)
		return -EIO;
	do {
		result = recvmsg(capability_fd, &message, MSG_CMSG_CLOEXEC);
	} while (result < 0 && errno == EINTR);
	if (result < 0)
		return -errno;
	for (control = CMSG_FIRSTHDR(&message); control != NULL;
		control = CMSG_NXTHDR(&message, control)) {
		if (control->cmsg_level != SOL_SOCKET
		    || control->cmsg_type != SCM_RIGHTS
		    || control->cmsg_len < CMSG_LEN(0)) {
			malformed_control = true;
			continue;
		}
		size_t bytes = control->cmsg_len - CMSG_LEN(0);
		if (bytes % sizeof(int) != 0) {
			malformed_control = true;
			continue;
		}
		int *fds = (int *) CMSG_DATA(control);
		for (size_t index = 0; index < bytes / sizeof(*fds); index++) {
			descriptors++;
			if (descriptor < 0)
				descriptor = fds[index];
			else
				close(fds[index]);
		}
	}
	if (result != ANDOCK_NETWORK_HEADER_SIZE + 4
	    || (message.msg_flags & (MSG_CTRUNC | MSG_TRUNC)) != 0
	    || malformed_control
	    || get_u32(response) != ANDOCK_NETWORK_MAGIC
	    || response[4] != ANDOCK_NETWORK_VERSION
	    || response[5] != (uint8_t) (opcode | ANDOCK_NETWORK_RESPONSE)
	    || get_u16(response + 6) != 0
	    || get_u32(response + 8) != id
	    || get_u32(response + 12) != 4) {
		if (descriptor >= 0)
			close(descriptor);
		else
			close_received_fds(&message);
		return -EPROTO;
	}
	uint32_t remote_errno = get_u32(response + ANDOCK_NETWORK_HEADER_SIZE);
	bool descriptors_valid = received_fd == NULL
		? descriptors == 0 : descriptors == 1;
	if (remote_errno > INT_MAX
	    || (remote_errno == 0 && !descriptors_valid)
	    || (remote_errno != 0 && descriptors != 0)) {
		if (descriptor >= 0)
			close(descriptor);
		return -EPROTO;
	}
	if (remote_errno != 0)
		return -(int) remote_errno;
	if (received_fd != NULL)
		*received_fd = descriptor;
	return 0;
}

int andock_network_start(int fd)
{
	if (fd < 0 || capability_fd >= 0)
		return -EINVAL;
	if (fcntl(fd, F_GETFD) < 0)
		return -errno;
	if (fcntl(fd, F_SETFD, FD_CLOEXEC) < 0)
		return -errno;
	capability_fd = fd;
	request_id = 0;
	return 0;
}

void andock_network_stop(void)
{
	if (capability_fd >= 0)
		close(capability_fd);
	capability_fd = -1;
	request_id = 0;
}

bool andock_network_enabled(void)
{
	return capability_fd >= 0;
}

int andock_network_create_socket(int family, int type, int protocol, int *fd)
{
	uint8_t payload[12];
	struct stat status;
	int socket_type;
	socklen_t socket_type_size = sizeof(socket_type);
	int result;

	if (fd == NULL)
		return -EINVAL;
	put_u32(payload, (uint32_t) family);
	put_u32(payload + 4, (uint32_t) type);
	put_u32(payload + 8, (uint32_t) protocol);
	result = call(ANDOCK_NETWORK_CREATE_SOCKET, payload, sizeof(payload), fd);
	if (result < 0)
		return result;
	if (fstat(*fd, &status) < 0 || !S_ISSOCK(status.st_mode)
	    || getsockopt(*fd, SOL_SOCKET, SO_TYPE,
		&socket_type, &socket_type_size) < 0
	    || socket_type_size != sizeof(socket_type)
	    || socket_type != (type & ~(SOCK_CLOEXEC | SOCK_NONBLOCK))) {
		close(*fd);
		*fd = -1;
		return -EPROTO;
	}
	return 0;
}

int andock_network_authorize(const struct sockaddr *address,
		socklen_t address_size, int transport)
{
	uint8_t payload[12 + sizeof(struct in6_addr)] = {};
	const void *raw_address;
	size_t raw_size;
	uint16_t port;
	uint32_t scope_id = 0;

	if (address == NULL || address_size < sizeof(address->sa_family))
		return -EFAULT;
	if (address->sa_family == AF_INET) {
		const struct sockaddr_in *ipv4 = (const struct sockaddr_in *) address;
		if (address_size < sizeof(*ipv4))
			return -EINVAL;
		raw_address = &ipv4->sin_addr;
		raw_size = sizeof(ipv4->sin_addr);
		port = ntohs(ipv4->sin_port);
	}
	else if (address->sa_family == AF_INET6) {
		const struct sockaddr_in6 *ipv6 = (const struct sockaddr_in6 *) address;
		if (address_size < sizeof(*ipv6) || ipv6->sin6_scope_id > INT_MAX)
			return -EINVAL;
		raw_address = &ipv6->sin6_addr;
		raw_size = sizeof(ipv6->sin6_addr);
		port = ntohs(ipv6->sin6_port);
		scope_id = ipv6->sin6_scope_id;
	}
	else {
		return -EAFNOSUPPORT;
	}
	put_u16(payload, (uint16_t) address->sa_family);
	payload[2] = (uint8_t) transport;
	put_u16(payload + 4, port);
	put_u16(payload + 6, (uint16_t) raw_size);
	put_u32(payload + 8, scope_id);
	memcpy(payload + 12, raw_address, raw_size);
	return call(ANDOCK_NETWORK_AUTHORIZE_DESTINATION,
		payload, 12 + raw_size, NULL);
}
