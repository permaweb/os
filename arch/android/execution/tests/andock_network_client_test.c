#define _GNU_SOURCE

#include <arpa/inet.h>
#include <errno.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#include "extension/andock_image/andock_network.h"

#define MAGIC 0x414e4431U
#define HEADER 16

struct server {
	int fd;
	bool malformed_authorization;
};

static uint16_t read_u16(const uint8_t *input)
{
	uint16_t value;
	memcpy(&value, input, sizeof(value));
	return ntohs(value);
}

static uint32_t read_u32(const uint8_t *input)
{
	uint32_t value;
	memcpy(&value, input, sizeof(value));
	return ntohl(value);
}

static void write_u32(uint8_t *output, uint32_t value)
{
	value = htonl(value);
	memcpy(output, &value, sizeof(value));
}

static void send_response(int fd, const uint8_t *request, int error,
		int descriptor)
{
	uint8_t response[HEADER + 4] = {};
	char control[CMSG_SPACE(sizeof(int))] = {};
	struct iovec vector = { .iov_base = response, .iov_len = sizeof(response) };
	struct msghdr message = { .msg_iov = &vector, .msg_iovlen = 1 };

	write_u32(response, MAGIC);
	response[4] = 1;
	response[5] = request[5] | 0x80;
	write_u32(response + 8, read_u32(request + 8));
	write_u32(response + 12, 4);
	write_u32(response + HEADER, (uint32_t) error);
	if (descriptor >= 0) {
		message.msg_control = control;
		message.msg_controllen = sizeof(control);
		struct cmsghdr *header = CMSG_FIRSTHDR(&message);
		header->cmsg_level = SOL_SOCKET;
		header->cmsg_type = SCM_RIGHTS;
		header->cmsg_len = CMSG_LEN(sizeof(descriptor));
		memcpy(CMSG_DATA(header), &descriptor, sizeof(descriptor));
	}
	if (sendmsg(fd, &message, MSG_NOSIGNAL) != sizeof(response)) {
		perror("send response");
		exit(1);
	}
}

static int receive_request(int fd, uint8_t request[64], uint8_t opcode)
{
	ssize_t size = recv(fd, request, 64, 0);
	if (size < HEADER || read_u32(request) != MAGIC || request[4] != 1
	    || request[5] != opcode || read_u16(request + 6) != 0
	    || read_u32(request + 12) != (uint32_t) size - HEADER) {
		fprintf(stderr, "malformed client request\n");
		exit(1);
	}
	return (int) size;
}

static void *serve(void *argument)
{
	struct server *server = argument;
	int server_fd = server->fd;
	bool malformed_authorization = server->malformed_authorization;
	uint8_t request[64];
	int socket_fd;

	free(server);
	if (malformed_authorization) {
		receive_request(server_fd, request, 2);
		socket_fd = socket(AF_INET, SOCK_DGRAM | SOCK_CLOEXEC, 0);
		send_response(server_fd, request, 0, socket_fd);
		close(socket_fd);
		close(server_fd);
		return NULL;
	}
	receive_request(server_fd, request, 1);
	if (read_u32(request + HEADER) != AF_INET
	    || read_u32(request + HEADER + 4) != SOCK_STREAM
	    || read_u32(request + HEADER + 8) != IPPROTO_TCP) {
		fprintf(stderr, "wrong create request\n");
		exit(1);
	}
	socket_fd = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, IPPROTO_TCP);
	send_response(server_fd, request, 0, socket_fd);
	close(socket_fd);
	receive_request(server_fd, request, 2);
	if (read_u16(request + HEADER) != AF_INET
	    || request[HEADER + 2] != SOCK_STREAM
	    || read_u16(request + HEADER + 4) != 443
	    || read_u16(request + HEADER + 6) != 4
	    || read_u32(request + HEADER + 8) != 0
	    || memcmp(request + HEADER + 12, "\x01\x01\x01\x01", 4) != 0) {
		fprintf(stderr, "wrong authorization request\n");
		exit(1);
	}
	send_response(server_fd, request, 0, -1);
	receive_request(server_fd, request, 1);
	send_response(server_fd, request, EPROTONOSUPPORT, -1);
	close(server_fd);
	return NULL;
}

static void run_server(bool malformed, pthread_t *thread, int *client)
{
	int sockets[2];
	struct server *server = malloc(sizeof(*server));
	if (server == NULL || socketpair(AF_UNIX,
		SOCK_SEQPACKET | SOCK_CLOEXEC, 0, sockets) < 0) {
		perror("socketpair");
		exit(1);
	}
	server->fd = sockets[1];
	server->malformed_authorization = malformed;
	*client = sockets[0];
	if (pthread_create(thread, NULL, serve, server) != 0) {
		perror("pthread_create");
		exit(1);
	}
}

static int udp_loopback_socket(struct sockaddr_in *address)
{
	socklen_t size = sizeof(*address);
	int fd = socket(AF_INET, SOCK_DGRAM | SOCK_CLOEXEC, 0);
	memset(address, 0, sizeof(*address));
	address->sin_family = AF_INET;
	address->sin_addr.s_addr = htonl(INADDR_LOOPBACK);
	if (fd < 0 || bind(fd, (struct sockaddr *) address, sizeof(*address)) < 0
	    || getsockname(fd, (struct sockaddr *) address, &size) < 0) {
		perror("UDP loopback socket");
		exit(1);
	}
	return fd;
}

static void send_udp_byte(int fd, const struct sockaddr_in *destination,
		char value)
{
	if (sendto(fd, &value, sizeof(value), 0,
		(struct sockaddr *) destination, sizeof(*destination)) != sizeof(value)) {
		perror("send UDP byte");
		exit(1);
	}
}

static void check_udp_peer_lock(void)
{
	struct sockaddr_in receiver_address;
	struct sockaddr_in attacker_address;
	struct sockaddr_in first_peer_address;
	struct sockaddr_in second_peer_address;
	struct sockaddr_in actual_peer = {};
	socklen_t actual_peer_size = sizeof(actual_peer);
	char value;
	int receiver = udp_loopback_socket(&receiver_address);
	int attacker = udp_loopback_socket(&attacker_address);
	int first_peer = udp_loopback_socket(&first_peer_address);
	int second_peer = udp_loopback_socket(&second_peer_address);

	if (sendto(attacker, NULL, 0, 0, (struct sockaddr *) &receiver_address,
		sizeof(receiver_address)) != 0)
		goto fail;
	send_udp_byte(attacker, &receiver_address, 'q');
	if (andock_network_lock_udp_peer(receiver,
		(struct sockaddr *) &first_peer_address,
		sizeof(first_peer_address)) != 0)
		goto fail;
	if (getpeername(receiver, (struct sockaddr *) &actual_peer,
		&actual_peer_size) < 0
	    || actual_peer.sin_port != first_peer_address.sin_port)
		goto fail;
	send_udp_byte(attacker, &receiver_address, 'x');
	send_udp_byte(first_peer, &receiver_address, 'a');
	if (recv(receiver, &value, 1, MSG_DONTWAIT) != 1 || value != 'a')
		goto fail;
	errno = 0;
	if (recv(receiver, &value, 1, MSG_DONTWAIT) >= 0
	    || (errno != EAGAIN && errno != EWOULDBLOCK))
		goto fail;

	send_udp_byte(first_peer, &receiver_address, 'o');
	if (andock_network_lock_udp_peer(receiver,
		(struct sockaddr *) &second_peer_address,
		sizeof(second_peer_address)) != 0)
		goto fail;
	send_udp_byte(first_peer, &receiver_address, 'y');
	send_udp_byte(second_peer, &receiver_address, 'b');
	if (recv(receiver, &value, 1, MSG_DONTWAIT) != 1 || value != 'b')
		goto fail;
	errno = 0;
	if (recv(receiver, &value, 1, MSG_DONTWAIT) >= 0
	    || (errno != EAGAIN && errno != EWOULDBLOCK))
		goto fail;
	close(second_peer);
	close(first_peer);
	close(attacker);
	close(receiver);
	return;

fail:
	fprintf(stderr, "UDP peer lock did not drain or filter datagrams\n");
	exit(1);
}

int main(void)
{
	struct sockaddr_in destination = {
		.sin_family = AF_INET,
		.sin_port = htons(443),
	};
	pthread_t thread;
	int client;
	int socket_fd;
	check_udp_peer_lock();

	inet_pton(AF_INET, "1.1.1.1", &destination.sin_addr);
	if (andock_network_create_socket(AF_INET, SOCK_STREAM, IPPROTO_TCP,
		&socket_fd) != -EACCES) {
		fprintf(stderr, "disabled client did not fail closed\n");
		return 1;
	}
	run_server(false, &thread, &client);
	if (andock_network_start(client) != 0
	    || andock_network_create_socket(AF_INET, SOCK_STREAM, IPPROTO_TCP,
		&socket_fd) != 0
	    || socket_fd < 0
	    || andock_network_authorize((struct sockaddr *) &destination,
		sizeof(destination), SOCK_STREAM) != 0
	    || andock_network_create_socket(AF_INET, SOCK_RAW, IPPROTO_TCP,
		&client) != -EPROTONOSUPPORT) {
		fprintf(stderr, "valid network protocol exchange failed\n");
		return 1;
	}
	close(socket_fd);
	andock_network_stop();
	pthread_join(thread, NULL);
	run_server(true, &thread, &client);
	if (andock_network_start(client) != 0
	    || andock_network_authorize((struct sockaddr *) &destination,
		sizeof(destination), SOCK_STREAM) != -EPROTO) {
		fprintf(stderr, "malformed descriptor response was accepted\n");
		return 1;
	}
	andock_network_stop();
	pthread_join(thread, NULL);
	puts("ANDOCK_NETWORK_CLIENT_TEST_OK");
	return 0;
}
