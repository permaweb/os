#define _GNU_SOURCE

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <linux/aio_abi.h>
#include <linux/netlink.h>
#include <net/ethernet.h>
#include <netpacket/packet.h>
#include <pthread.h>
#include <sched.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <sys/un.h>
#include <sys/uio.h>
#include <sys/wait.h>
#include <unistd.h>

#ifndef SYS_close_range
#define SYS_close_range 436
#endif
#ifndef SYS_pidfd_getfd
#define SYS_pidfd_getfd 438
#endif
#ifndef SYS_io_uring_setup
#define SYS_io_uring_setup 425
#endif
#ifndef CLOSE_RANGE_UNSHARE
#define CLOSE_RANGE_UNSHARE (1U << 1)
#endif
#ifndef CLOSE_RANGE_CLOEXEC
#define CLOSE_RANGE_CLOEXEC (1U << 2)
#endif

static const char *program_path;

static void fail(const char *operation)
{
	fprintf(stderr, "%s: %s (%d)\n", operation, strerror(errno), errno);
	exit(1);
}

static void require(bool condition, const char *operation)
{
	if (!condition) {
		errno = EPROTO;
		fail(operation);
	}
}

static struct sockaddr_in ipv4(const char *address, int port)
{
	struct sockaddr_in result = {
		.sin_family = AF_INET,
		.sin_port = htons((uint16_t) port),
	};
	require(inet_pton(AF_INET, address, &result.sin_addr) == 1, "inet_pton");
	return result;
}

static int udp_socket(void)
{
	int fd = socket(AF_INET, SOCK_DGRAM, 0);
	if (fd < 0)
		fail("socket");
	return fd;
}

static void send_public(int fd)
{
	char byte = 'x';
	struct sockaddr_in target = ipv4("1.1.1.1", 443);
	if (sendto(fd, &byte, sizeof(byte), 0,
		(struct sockaddr *) &target, sizeof(target)) != sizeof(byte))
		fail("sendto public");
}

static void expect_denied_private(int fd)
{
	char byte = 'x';
	struct sockaddr_in target = ipv4("127.0.0.1", 8734);
	errno = 0;
	require(sendto(fd, &byte, sizeof(byte), 0,
		(struct sockaddr *) &target, sizeof(target)) < 0,
		"private sendto unexpectedly succeeded");
	require(errno == EACCES || errno == EPERM, "private sendto wrong errno");
}

static void send_public_message(int fd)
{
	char first[] = "and";
	char second[] = "ock";
	struct iovec vectors[] = {
		{ .iov_base = first, .iov_len = sizeof(first) - 1 },
		{ .iov_base = second, .iov_len = sizeof(second) - 1 },
	};
	struct sockaddr_in target = ipv4("1.1.1.1", 443);
	struct msghdr message = {
		.msg_name = &target,
		.msg_namelen = sizeof(target),
		.msg_iov = vectors,
		.msg_iovlen = 2,
	};
	if (sendmsg(fd, &message, 0) != 6)
		fail("sendmsg public");
}

static void send_public_messages(int fd)
{
	char first = 'a';
	char second = 'b';
	struct iovec vectors[] = {
		{ .iov_base = &first, .iov_len = 1 },
		{ .iov_base = &second, .iov_len = 1 },
	};
	struct sockaddr_in targets[] = {
		ipv4("1.1.1.1", 443),
		ipv4("1.1.1.1", 443),
	};
	struct mmsghdr messages[2] = {};
	for (size_t index = 0; index < 2; index++) {
		messages[index].msg_hdr.msg_name = &targets[index];
		messages[index].msg_hdr.msg_namelen = sizeof(targets[index]);
		messages[index].msg_hdr.msg_iov = &vectors[index];
		messages[index].msg_hdr.msg_iovlen = 1;
	}
	if (sendmmsg(fd, messages, 2, 0) != 2)
		fail("sendmmsg public");
	require(messages[0].msg_len == 1 && messages[1].msg_len == 1,
		"sendmmsg lengths");
}

static void expect_sendmmsg_multi_peer_denied(int fd)
{
	char bytes[] = { 'a', 'b' };
	struct iovec vectors[] = {
		{ .iov_base = &bytes[0], .iov_len = 1 },
		{ .iov_base = &bytes[1], .iov_len = 1 },
	};
	struct sockaddr_in targets[] = {
		ipv4("1.1.1.1", 443),
		ipv4("8.8.8.8", 443),
	};
	struct mmsghdr messages[2] = {};
	for (size_t index = 0; index < 2; index++) {
		messages[index].msg_hdr.msg_name = &targets[index];
		messages[index].msg_hdr.msg_namelen = sizeof(targets[index]);
		messages[index].msg_hdr.msg_iov = &vectors[index];
		messages[index].msg_hdr.msg_iovlen = 1;
	}
	errno = 0;
	require(sendmmsg(fd, messages, 2, 0) < 0,
		"multi-peer sendmmsg unexpectedly succeeded");
	require(errno == EOPNOTSUPP, "multi-peer sendmmsg wrong errno");
	require(messages[0].msg_len == 0 && messages[1].msg_len == 0,
		"multi-peer sendmmsg partially executed");
}

static void exercise_unconnected_udp_reply_peer(void)
{
	struct sockaddr_storage peer = {};
	socklen_t peer_size = sizeof(peer);
	struct sockaddr_in second = ipv4("8.8.8.8", 443);
	char byte = 'x';
	int fd = udp_socket();

	send_public(fd);
	errno = 0;
	require(getpeername(fd, (struct sockaddr *) &peer, &peer_size) < 0,
		"unconnected UDP exposed pinned reply peer");
	require(errno == ENOTCONN, "unconnected UDP getpeername wrong errno");
	require(sendto(fd, &byte, 1, 0,
		(struct sockaddr *) &second, sizeof(second)) == 1,
		"unconnected UDP reply-peer repin");
	peer_size = sizeof(peer);
	errno = 0;
	require(getpeername(fd, (struct sockaddr *) &peer, &peer_size) < 0,
		"repinned unconnected UDP exposed peer");
	require(errno == ENOTCONN, "repinned UDP getpeername wrong errno");
	close(fd);
}

static void expect_udp_disconnect_denied(void)
{
	struct sockaddr_in peer = ipv4("1.1.1.1", 443);
	struct sockaddr disconnect = { .sa_family = AF_UNSPEC };
	int fd = udp_socket();

	require(connect(fd, (struct sockaddr *) &peer, sizeof(peer)) == 0,
		"UDP connect before disconnect denial");
	errno = 0;
	require(connect(fd, &disconnect, sizeof(disconnect)) < 0,
		"UDP disconnect unexpectedly succeeded");
	require(errno == EACCES || errno == EPERM,
		"UDP disconnect wrong errno");
	close(fd);
}

static void expect_udp_receive_without_peer_denied(void)
{
	struct sockaddr_in any = ipv4("0.0.0.0", 0);
	struct sockaddr_storage source = {};
	socklen_t source_size = sizeof(source);
	char byte;
	struct iovec vector = { .iov_base = &byte, .iov_len = 1 };
	struct msghdr message = {
		.msg_name = &source,
		.msg_namelen = sizeof(source),
		.msg_iov = &vector,
		.msg_iovlen = 1,
	};
	struct mmsghdr messages[1] = {};
	int channel[2];
	int fd = udp_socket();

	require(bind(fd, (struct sockaddr *) &any, sizeof(any)) == 0,
		"pre-peer UDP bind");
	messages[0].msg_hdr = message;
	errno = 0;
	require(recvfrom(fd, &byte, 1, MSG_DONTWAIT,
		(struct sockaddr *) &source, &source_size) < 0,
		"pre-peer recvfrom unexpectedly succeeded");
	require(errno == ENOTCONN, "pre-peer recvfrom wrong errno");
	errno = 0;
	require(recvmsg(fd, &message, MSG_DONTWAIT | MSG_PEEK) < 0,
		"pre-peer recvmsg unexpectedly succeeded");
	require(errno == ENOTCONN, "pre-peer recvmsg wrong errno");
	errno = 0;
	require(recvmmsg(fd, messages, 1, MSG_DONTWAIT, NULL) < 0,
		"pre-peer recvmmsg unexpectedly succeeded");
	require(errno == ENOTCONN, "pre-peer recvmmsg wrong errno");
	errno = 0;
	require(read(fd, &byte, 1) < 0,
		"pre-peer read unexpectedly succeeded");
	require(errno == ENOTCONN, "pre-peer read wrong errno");
	errno = 0;
	require(readv(fd, &vector, 1) < 0,
		"pre-peer readv unexpectedly succeeded");
	require(errno == ENOTCONN, "pre-peer readv wrong errno");
	errno = 0;
	require(preadv2(fd, &vector, 1, -1, 0) < 0,
		"pre-peer preadv2 unexpectedly succeeded");
	require(errno == ENOTCONN, "pre-peer preadv2 wrong errno");
	require(pipe(channel) == 0, "pre-peer splice pipe");
	errno = 0;
	require(splice(fd, NULL, channel[1], NULL, 1, SPLICE_F_NONBLOCK) < 0,
		"pre-peer splice unexpectedly succeeded");
	require(errno == ENOTCONN, "pre-peer splice wrong errno");
	close(channel[0]);
	close(channel[1]);
	close(fd);
}

static void expect_sendmmsg_atomic_denial(int fd)
{
	char bytes[] = { 'a', 'b' };
	struct iovec vectors[] = {
		{ .iov_base = &bytes[0], .iov_len = 1 },
		{ .iov_base = &bytes[1], .iov_len = 1 },
	};
	struct sockaddr_in targets[] = {
		ipv4("1.1.1.1", 443),
		ipv4("127.0.0.1", 8734),
	};
	struct mmsghdr messages[2] = {};
	for (size_t index = 0; index < 2; index++) {
		messages[index].msg_hdr.msg_name = &targets[index];
		messages[index].msg_hdr.msg_namelen = sizeof(targets[index]);
		messages[index].msg_hdr.msg_iov = &vectors[index];
		messages[index].msg_hdr.msg_iovlen = 1;
	}
	errno = 0;
	require(sendmmsg(fd, messages, 2, 0) < 0,
		"mixed sendmmsg unexpectedly succeeded");
	require(errno == EACCES || errno == EPERM, "mixed sendmmsg wrong errno");
	require(messages[0].msg_len == 0 && messages[1].msg_len == 0,
		"mixed sendmmsg partially executed");
}

static void exercise_ipv6(void)
{
	int fd = socket(AF_INET6, SOCK_DGRAM, 0);
	char byte = '6';
	struct sockaddr_in6 public_address = {
		.sin6_family = AF_INET6,
		.sin6_port = htons(443),
	};
	struct sockaddr_in6 private_address = {
		.sin6_family = AF_INET6,
		.sin6_port = htons(8734),
	};
	if (fd < 0)
		fail("IPv6 socket");
	require(inet_pton(AF_INET6, "2606:4700:4700::1111",
		&public_address.sin6_addr) == 1, "IPv6 public address");
	require(inet_pton(AF_INET6, "::1", &private_address.sin6_addr) == 1,
		"IPv6 private address");
	errno = 0;
	ssize_t result = sendto(fd, &byte, 1, 0,
		(struct sockaddr *) &public_address, sizeof(public_address));
	if (result < 0)
		require(errno == ENETUNREACH || errno == EHOSTUNREACH,
			"IPv6 public wrong errno");
	else
		require(result == 1, "IPv6 public wrong result");
	errno = 0;
	require(sendto(fd, &byte, 1, 0,
		(struct sockaddr *) &private_address, sizeof(private_address)) < 0,
		"IPv6 private unexpectedly succeeded");
	require(errno == EACCES || errno == EPERM, "IPv6 private wrong errno");
	close(fd);
}

static void exercise_ephemeral_udp_bind(void)
{
	struct sockaddr_in any = ipv4("0.0.0.0", 0);
	struct sockaddr_in loopback = ipv4("127.0.0.1", 0);
	struct sockaddr_in fixed = ipv4("0.0.0.0", 5353);
	struct sockaddr_in bound = {};
	struct sockaddr_in6 any6 = {
		.sin6_family = AF_INET6,
	};
	struct sockaddr_in6 loopback6 = {
		.sin6_family = AF_INET6,
		.sin6_addr = IN6ADDR_LOOPBACK_INIT,
	};
	struct sockaddr_in6 fixed6 = {
		.sin6_family = AF_INET6,
		.sin6_port = htons(5353),
	};
	struct sockaddr_in6 bound6 = {};
	socklen_t bound_size = sizeof(bound);
	socklen_t bound6_size = sizeof(bound6);
	int fd = udp_socket();
	require(bind(fd, (struct sockaddr *) &any, sizeof(any)) == 0,
		"IPv4 ephemeral UDP bind");
	require(getsockname(fd, (struct sockaddr *) &bound, &bound_size) == 0,
		"IPv4 ephemeral getsockname");
	require(bound.sin_family == AF_INET && ntohs(bound.sin_port) != 0,
		"IPv4 ephemeral bind result");
	errno = 0;
	require(listen(fd, 1) < 0, "UDP listen unexpectedly succeeded");
	require(errno == EACCES || errno == EPERM || errno == EOPNOTSUPP,
		"UDP listen wrong errno");
	close(fd);

	fd = udp_socket();
	errno = 0;
	require(bind(fd, (struct sockaddr *) &loopback, sizeof(loopback)) < 0,
		"loopback UDP bind unexpectedly succeeded");
	require(errno == EACCES || errno == EPERM,
		"loopback UDP bind wrong errno");
	errno = 0;
	require(bind(fd, (struct sockaddr *) &fixed, sizeof(fixed)) < 0,
		"fixed UDP bind unexpectedly succeeded");
	require(errno == EACCES || errno == EPERM, "fixed UDP bind wrong errno");
	close(fd);

	fd = socket(AF_INET6, SOCK_DGRAM, 0);
	if (fd < 0)
		fail("IPv6 bind socket");
	require(bind(fd, (struct sockaddr *) &any6, sizeof(any6)) == 0,
		"IPv6 ephemeral UDP bind");
	require(getsockname(fd, (struct sockaddr *) &bound6, &bound6_size) == 0,
		"IPv6 ephemeral getsockname");
	require(bound6.sin6_family == AF_INET6
		&& ntohs(bound6.sin6_port) != 0,
		"IPv6 ephemeral bind result");
	close(fd);

	fd = socket(AF_INET6, SOCK_DGRAM, 0);
	if (fd < 0)
		fail("IPv6 denial socket");
	errno = 0;
	require(bind(fd, (struct sockaddr *) &loopback6, sizeof(loopback6)) < 0,
		"IPv6 loopback UDP bind unexpectedly succeeded");
	require(errno == EACCES || errno == EPERM,
		"IPv6 loopback UDP bind wrong errno");
	errno = 0;
	require(bind(fd, (struct sockaddr *) &fixed6, sizeof(fixed6)) < 0,
		"IPv6 fixed UDP bind unexpectedly succeeded");
	require(errno == EACCES || errno == EPERM,
		"IPv6 fixed UDP bind wrong errno");
	close(fd);

	fd = socket(AF_INET, SOCK_STREAM, 0);
	if (fd < 0)
		fail("TCP bind socket");
	errno = 0;
	require(bind(fd, (struct sockaddr *) &any, sizeof(any)) < 0,
		"TCP ephemeral bind unexpectedly succeeded");
	require(errno == EACCES || errno == EPERM,
		"TCP ephemeral bind wrong errno");
	close(fd);
}

static void expect_dangerous_socket_denied(
		int family, int type, int protocol, const char *operation)
{
	errno = 0;
	int fd = socket(family, type, protocol);
	if (fd >= 0) {
		close(fd);
		errno = 0;
		fail(operation);
	}
	require(errno == EACCES || errno == EPERM || errno == EPROTONOSUPPORT,
		operation);
}

static void expect_scm_rights_denied(int passed_fd)
{
	int channel[2];
	char byte = 0;
	char control[CMSG_SPACE(sizeof(int))] = {};
	struct iovec vector = { .iov_base = &byte, .iov_len = 1 };
	struct msghdr message = {
		.msg_iov = &vector,
		.msg_iovlen = 1,
		.msg_control = control,
		.msg_controllen = sizeof(control),
	};
	struct cmsghdr *header = CMSG_FIRSTHDR(&message);
	require(socketpair(AF_UNIX, SOCK_SEQPACKET, 0, channel) == 0, "socketpair");
	header->cmsg_level = SOL_SOCKET;
	header->cmsg_type = SCM_RIGHTS;
	header->cmsg_len = CMSG_LEN(sizeof(int));
	memcpy(CMSG_DATA(header), &passed_fd, sizeof(passed_fd));
	errno = 0;
	require(sendmsg(channel[0], &message, 0) < 0,
		"SCM_RIGHTS descriptor pass unexpectedly succeeded");
	require(errno == EPERM || errno == EACCES, "SCM_RIGHTS wrong errno");
	close(channel[0]);
	close(channel[1]);
}

static void exercise_plain_unix_sendmsg(void)
{
	int channel[2];
	char sent[] = "plain";
	char received[sizeof(sent)] = {};
	struct iovec output = { .iov_base = sent, .iov_len = sizeof(sent) };
	struct iovec input = { .iov_base = received, .iov_len = sizeof(received) };
	struct msghdr message = { .msg_iov = &output, .msg_iovlen = 1 };
	require(socketpair(AF_UNIX, SOCK_DGRAM, 0, channel) == 0,
		"plain sendmsg socketpair");
	require(sendmsg(channel[0], &message, 0) == sizeof(sent),
		"plain Unix sendmsg");
	message.msg_iov = &input;
	require(recvmsg(channel[1], &message, 0) == sizeof(sent),
		"plain Unix recvmsg");
	require(memcmp(sent, received, sizeof(sent)) == 0,
		"plain Unix sendmsg content");
	close(channel[0]);
	close(channel[1]);
}

static void expect_image_fd_policies(void)
{
	char payload[] = "aio";
	aio_context_t context = 0;
	int fd = open("/root/andock-fd-policy", O_CREAT | O_TRUNC | O_RDWR, 0600);
	require(fd >= 0, "open image fd policy fixture");
	require(ftruncate(fd, 4096) == 0, "size image fd policy fixture");
	require(pwrite(fd, payload, sizeof(payload), 0) == sizeof(payload),
		"write image fd policy fixture");
	close(fd);
	fd = open("/root/andock-fd-policy", O_RDONLY);
	require(fd >= 0, "reopen image fd policy fixture read-only");
	errno = 0;
	require(write(fd, payload, sizeof(payload)) < 0 && errno == EBADF,
		"read-only image write unexpectedly succeeded");
	errno = 0;
	void *mapping = mmap(NULL, 4096, PROT_READ | PROT_WRITE,
		MAP_SHARED, fd, 0);
	require(mapping == MAP_FAILED && errno == EACCES,
		"read-only image writable mmap unexpectedly succeeded");
	mapping = mmap(NULL, 4096, PROT_READ, MAP_SHARED, fd, 0);
	require(mapping != MAP_FAILED, "read-only image mmap");
	errno = 0;
	require(mprotect(mapping, 4096, PROT_READ | PROT_WRITE) < 0
		&& errno == EACCES,
		"read-only image mprotect unexpectedly succeeded");
	munmap(mapping, 4096);
	close(fd);
	fd = open("/root/andock-fd-policy", O_RDWR);
	require(fd >= 0, "reopen image fd policy fixture read-write");
	expect_scm_rights_denied(fd);
	exercise_plain_unix_sendmsg();
	errno = 0;
	long setup = syscall(SYS_io_setup, 1, &context);
	if (setup == 0) {
		struct iocb request = {
			.aio_lio_opcode = IOCB_CMD_PWRITE,
			.aio_fildes = (uint32_t)fd,
			.aio_buf = (uint64_t)(uintptr_t)payload,
			.aio_nbytes = sizeof(payload),
		};
		struct iocb *requests[] = { &request };
		errno = 0;
		require(syscall(SYS_io_submit, context, 1, requests) < 0,
			"legacy AIO image write unexpectedly succeeded");
		require(errno == EOPNOTSUPP || errno == EPERM || errno == ENOSYS,
			"legacy AIO denial wrong errno");
		require(syscall(SYS_io_destroy, context) == 0,
			"legacy AIO context destroy");
	}
	else
		require(errno == EPERM || errno == ENOSYS,
			"legacy AIO setup wrong errno");
	struct stat metadata;
	require(fstat(fd, &metadata) == 0 && metadata.st_size == 4096,
		"legacy AIO changed image file");
	close(fd);
	unlink("/root/andock-fd-policy");
}

static void wait_success(pid_t child, const char *operation)
{
	int status;
	require(waitpid(child, &status, 0) == child, operation);
	require(WIFEXITED(status) && WEXITSTATUS(status) == 0, operation);
}

static struct sockaddr_un unix_address(const char *path)
{
	struct sockaddr_un address = { .sun_family = AF_UNIX };
	require(strlen(path) < sizeof(address.sun_path), "Unix socket path length");
	strcpy(address.sun_path, path);
	return address;
}

static int unix_listener(const char *path)
{
	struct sockaddr_un address = unix_address(path);
	int fd = socket(AF_UNIX, SOCK_STREAM, 0);
	if (fd < 0)
		fail("Unix socket");
	if (bind(fd, (struct sockaddr *) &address, sizeof(address)) < 0)
		fail("Unix bind");
	if (listen(fd, 4) < 0)
		fail("Unix listen");
	return fd;
}

static int unix_connect(const char *path)
{
	struct sockaddr_un address = unix_address(path);
	int fd = socket(AF_UNIX, SOCK_STREAM, 0);
	if (fd < 0)
		fail("Unix client socket");
	if (connect(fd, (struct sockaddr *) &address, sizeof(address)) < 0)
		fail("Unix client connect");
	return fd;
}

static void expect_unix_name(int fd, const char *expected)
{
	struct sockaddr_un address;
	socklen_t size = sizeof(address);
	memset(&address, 0, sizeof(address));
	require(getsockname(fd, (struct sockaddr *) &address, &size) == 0,
		"Unix getsockname");
	require(address.sun_family == AF_UNIX
		&& strcmp(address.sun_path, expected) == 0,
		"Unix getsockname path");
}

static mode_t path_mode(const char *path)
{
	struct stat metadata;
	if (lstat(path, &metadata) < 0)
		fail("lstat mode");
	return metadata.st_mode;
}

static void exercise_unix_socket_lifecycle(void)
{
	const char *path = "/root/andock-path.sock";
	struct sockaddr_un address = unix_address(path);
	char byte = 'x';
	int server;
	int second_server;
	int client;
	int accepted;
	unlink(path);
	umask(022);
	server = unix_listener(path);
	require(S_ISSOCK(path_mode(path)), "Unix bind did not create socket node");
	require((path_mode(path) & 0777) == 0755, "Unix socket 022 mode");
	client = socket(AF_UNIX, SOCK_STREAM, 0);
	require(client >= 0, "second Unix socket");
	errno = 0;
	require(bind(client, (struct sockaddr *) &address, sizeof(address)) < 0,
		"duplicate Unix bind unexpectedly succeeded");
	require(errno == EADDRINUSE, "duplicate Unix bind wrong errno");
	close(client);
	client = socket(AF_UNIX, SOCK_STREAM, 0);
	require(client >= 0, "Unix client socket");
	require(connect(client, (struct sockaddr *) &address, sizeof(address)) == 0,
		"Unix connect");
	accepted = accept(server, NULL, NULL);
	require(accepted >= 0, "Unix accept");
	require(write(client, &byte, 1) == 1, "Unix client write");
	byte = 0;
	require(read(accepted, &byte, 1) == 1 && byte == 'x', "Unix server read");
	close(accepted);
	close(client);
	require(unlink(path) == 0, "unlink live Unix socket");
	client = socket(AF_UNIX, SOCK_STREAM, 0);
	require(client >= 0, "unlinked Unix client socket");
	errno = 0;
	require(connect(client, (struct sockaddr *) &address, sizeof(address)) < 0,
		"connect after Unix unlink unexpectedly succeeded");
	require(errno == ENOENT, "connect after Unix unlink wrong errno");
	close(client);
	second_server = unix_listener(path);
	client = socket(AF_UNIX, SOCK_STREAM, 0);
	require(client >= 0, "rebound Unix client socket");
	require(connect(client, (struct sockaddr *) &address, sizeof(address)) == 0,
		"connect to rebound Unix socket");
	accepted = accept(second_server, NULL, NULL);
	require(accepted >= 0, "accept rebound Unix socket");
	close(accepted);
	close(client);
	close(second_server);
	require(unlink(path) == 0, "unlink rebound Unix socket");
	close(server);
}

struct UnixBindRace {
	const char *path;
	pthread_barrier_t barrier;
	int result[2];
	int error[2];
	int descriptor[2];
};

struct UnixBindThread {
	struct UnixBindRace *race;
	int index;
};

static void *race_unix_bind(void *opaque)
{
	struct UnixBindThread *thread = opaque;
	struct UnixBindRace *race = thread->race;
	struct sockaddr_un address = unix_address(race->path);
	int index = thread->index;
	int barrier_result;
	race->descriptor[index] = socket(AF_UNIX, SOCK_STREAM, 0);
	require(race->descriptor[index] >= 0, "raced Unix socket");
	barrier_result = pthread_barrier_wait(&race->barrier);
	require(barrier_result == 0 || barrier_result == PTHREAD_BARRIER_SERIAL_THREAD,
		"Unix bind barrier");
	errno = 0;
	race->result[index] = bind(race->descriptor[index],
		(struct sockaddr *) &address, sizeof(address));
	race->error[index] = errno;
	return NULL;
}

static void exercise_unix_bind_race(void)
{
	const char *path = "/root/andock-bind-race.sock";
	struct UnixBindRace race = { .path = path };
	struct UnixBindThread arguments[2];
	pthread_t threads[2];
	int successes = 0;
	int collisions = 0;
	unlink(path);
	require(pthread_barrier_init(&race.barrier, NULL, 2) == 0,
		"Unix bind barrier init");
	for (int index = 0; index < 2; index++) {
		arguments[index] = (struct UnixBindThread) {
			.race = &race,
			.index = index,
		};
		require(pthread_create(&threads[index], NULL, race_unix_bind,
			&arguments[index]) == 0, "Unix bind pthread_create");
	}
	for (int index = 0; index < 2; index++) {
		require(pthread_join(threads[index], NULL) == 0,
			"Unix bind pthread_join");
		if (race.result[index] == 0)
			successes++;
		else if (race.error[index] == EADDRINUSE)
			collisions++;
		close(race.descriptor[index]);
	}
	require(successes == 1 && collisions == 1, "simultaneous Unix bind result");
	require(S_ISSOCK(path_mode(path)), "simultaneous Unix bind node");
	require(unlink(path) == 0, "unlink simultaneous Unix bind node");
	pthread_barrier_destroy(&race.barrier);
}

static void exercise_unix_socket_aliases(void)
{
	const char *source_path = "/root/andock-rename-source.sock";
	const char *target_path = "/root/andock-rename-target.sock";
	const char *link_path = "/root/andock-link.sock";
	const char *old_directory = "/root/andock-socket-dir-old";
	const char *new_directory = "/root/andock-socket-dir-new";
	const char *old_nested = "/root/andock-socket-dir-old/server.sock";
	const char *new_nested = "/root/andock-socket-dir-new/server.sock";
	struct sockaddr_un source_address = unix_address(source_path);
	int source;
	int target;
	int nested;
	int client;
	int accepted;
	unlink(source_path);
	unlink(target_path);
	unlink(link_path);
	source = unix_listener(source_path);
	target = unix_listener(target_path);
	expect_unix_name(source, source_path);
	expect_unix_name(target, target_path);
	require(rename(source_path, target_path) == 0,
		"rename Unix socket over existing");
	client = unix_connect(target_path);
	accepted = accept(source, NULL, NULL);
	require(accepted >= 0, "accept renamed Unix socket");
	close(accepted);
	close(client);
	expect_unix_name(source, source_path);
	expect_unix_name(target, target_path);
	errno = 0;
	client = socket(AF_UNIX, SOCK_STREAM, 0);
	require(client >= 0, "old-name Unix client");
	require(connect(client, (struct sockaddr *) &source_address,
		sizeof(source_address)) < 0, "old Unix name still connected");
	require(errno == ENOENT, "old Unix name wrong errno");
	close(client);
	require(link(target_path, link_path) == 0, "link Unix socket node");
	client = unix_connect(link_path);
	accepted = accept(source, NULL, NULL);
	require(accepted >= 0, "accept linked Unix socket");
	close(accepted);
	close(client);
	expect_unix_name(source, source_path);
	require(unlink(link_path) == 0, "unlink Unix socket alias");
	require(unlink(target_path) == 0, "unlink renamed Unix socket");
	close(source);
	close(target);
	rmdir(old_directory);
	rmdir(new_directory);
	require(mkdir(old_directory, 0755) == 0, "mkdir Unix socket parent");
	nested = unix_listener(old_nested);
	require(rename(old_directory, new_directory) == 0,
		"rename Unix socket parent directory");
	client = unix_connect(new_nested);
	accepted = accept(nested, NULL, NULL);
	require(accepted >= 0, "accept parent-renamed Unix socket");
	close(accepted);
	close(client);
	expect_unix_name(nested, old_nested);
	require(unlink(new_nested) == 0, "unlink parent-renamed Unix socket");
	close(nested);
	require(rmdir(new_directory) == 0,
		"remove renamed Unix socket parent");
}

static void exercise_failed_unix_bind_retry(void)
{
	const char *path = "/root/andock-bind-retry.sock";
	struct sockaddr_un address = unix_address(path);
	struct stat metadata;
	int non_socket;
	int server;
	unlink(path);
	non_socket = open("/root/andock-bind-retry.file",
		O_CREAT | O_TRUNC | O_RDWR, 0600);
	require(non_socket >= 0, "open failed-bind descriptor");
	errno = 0;
	require(bind(non_socket, (struct sockaddr *) &address, sizeof(address)) < 0,
		"bind on file unexpectedly succeeded");
	require(errno == ENOTSOCK, "bind on file wrong errno");
	errno = 0;
	require(lstat(path, &metadata) < 0 && errno == ENOENT,
		"failed bind leaked socket node");
	close(non_socket);
	unlink("/root/andock-bind-retry.file");
	server = unix_listener(path);
	close(server);
	require(unlink(path) == 0, "unlink failed-bind retry node");
}

static void *set_shared_umask(void *opaque)
{
	mode_t *mask = opaque;
	umask(*mask);
	return NULL;
}

static void exercise_umask_semantics(void)
{
	pthread_t thread;
	mode_t thread_mask = 077;
	pid_t child;
	int fd;
	int server;
	umask(077);
	fd = open("/root/andock-umask-077-file",
		O_CREAT | O_EXCL | O_WRONLY, 0666);
	require(fd >= 0, "create umask 077 file");
	close(fd);
	require(mkdir("/root/andock-umask-077-dir", 0777) == 0,
		"create umask 077 directory");
	require((path_mode("/root/andock-umask-077-file") & 0777) == 0600,
		"file umask 077 mode");
	require((path_mode("/root/andock-umask-077-dir") & 0777) == 0700,
		"directory umask 077 mode");
	server = unix_listener("/root/andock-umask-077.sock");
	require((path_mode("/root/andock-umask-077.sock") & 0777) == 0700,
		"socket umask 077 mode");
	close(server);
	require(unlink("/root/andock-umask-077.sock") == 0,
		"unlink umask 077 socket");
	umask(027);
	fd = open("/root/andock-umask-027-file",
		O_CREAT | O_EXCL | O_WRONLY, 0666);
	require(fd >= 0, "create umask 027 file");
	close(fd);
	require(mkdir("/root/andock-umask-027-dir", 0777) == 0,
		"create umask 027 directory");
	require((path_mode("/root/andock-umask-027-file") & 0777) == 0640,
		"file umask 027 mode");
	require((path_mode("/root/andock-umask-027-dir") & 0777) == 0750,
		"directory umask 027 mode");
	server = unix_listener("/root/andock-umask-027.sock");
	require((path_mode("/root/andock-umask-027.sock") & 0777) == 0750,
		"socket umask 027 mode");
	close(server);
	require(unlink("/root/andock-umask-027.sock") == 0,
		"unlink umask 027 socket");
	umask(022);
	require(pthread_create(&thread, NULL, set_shared_umask, &thread_mask) == 0,
		"umask pthread_create");
	require(pthread_join(thread, NULL) == 0, "umask pthread_join");
	fd = open("/root/andock-umask-thread-file",
		O_CREAT | O_EXCL | O_WRONLY, 0666);
	require(fd >= 0, "create shared umask file");
	close(fd);
	require((path_mode("/root/andock-umask-thread-file") & 0777) == 0600,
		"CLONE_FS did not share umask");
	child = fork();
	if (child < 0)
		fail("umask fork");
	if (child == 0) {
		umask(022);
		fd = open("/root/andock-umask-child-file",
			O_CREAT | O_EXCL | O_WRONLY, 0666);
		require(fd >= 0, "create child umask file");
		close(fd);
		_exit(0);
	}
	wait_success(child, "umask child");
	fd = open("/root/andock-umask-parent-file",
		O_CREAT | O_EXCL | O_WRONLY, 0666);
	require(fd >= 0, "create parent umask file");
	close(fd);
	require((path_mode("/root/andock-umask-child-file") & 0777) == 0644,
		"fork child umask mode");
	require((path_mode("/root/andock-umask-parent-file") & 0777) == 0600,
		"fork child changed parent umask");
	errno = 0;
	require(unshare(CLONE_FS) < 0, "unshare CLONE_FS unexpectedly succeeded");
	require(errno == EACCES || errno == EPERM, "unshare CLONE_FS wrong errno");
	umask(022);
	const char *paths[] = {
		"/root/andock-umask-077-file", "/root/andock-umask-027-file",
		"/root/andock-umask-thread-file", "/root/andock-umask-child-file",
		"/root/andock-umask-parent-file",
	};
	for (size_t index = 0; index < sizeof(paths) / sizeof(paths[0]); index++)
		require(unlink(paths[index]) == 0, "unlink umask file");
	require(rmdir("/root/andock-umask-077-dir") == 0,
		"remove umask 077 directory");
	require(rmdir("/root/andock-umask-027-dir") == 0,
		"remove umask 027 directory");
}

static struct flock whole_file_lock(short type)
{
	return (struct flock) {
		.l_type = type,
		.l_whence = SEEK_SET,
		.l_start = 0,
		.l_len = 0,
	};
}

static void child_can_lock(int fd, const char *operation)
{
	pid_t child = fork();
	if (child < 0)
		fail(operation);
	if (child == 0) {
		struct flock lock = whole_file_lock(F_WRLCK);
		require(fcntl(fd, F_SETLK, &lock) == 0, operation);
		lock.l_type = F_UNLCK;
		require(fcntl(fd, F_SETLK, &lock) == 0, operation);
		_exit(0);
	}
	wait_success(child, operation);
}

static void child_observes_parent_lock(int fd, bool close_descriptor,
		const char *operation)
{
	pid_t child = fork();
	if (child < 0)
		fail(operation);
	if (child == 0) {
		struct flock lock = whole_file_lock(F_WRLCK);
		require(fcntl(fd, F_GETLK, &lock) == 0, operation);
		require(lock.l_type == F_WRLCK && lock.l_pid > 0, operation);
		lock = whole_file_lock(F_WRLCK);
		errno = 0;
		require(fcntl(fd, F_SETLK, &lock) < 0, operation);
		require(errno == EACCES || errno == EAGAIN, operation);
		errno = 0;
		require(fcntl(fd, F_SETLKW, &lock) < 0, operation);
		require(errno == EOPNOTSUPP, operation);
		if (close_descriptor)
			close(fd);
		_exit(0);
	}
	wait_success(child, operation);
}

struct ThreadLockState {
	int fd;
};

static void *observe_and_unlock_process_lock(void *opaque)
{
	struct ThreadLockState *state = opaque;
	struct flock lock = whole_file_lock(F_WRLCK);
	require(fcntl(state->fd, F_GETLK, &lock) == 0,
		"thread F_GETLK");
	require(lock.l_type == F_UNLCK, "thread lock owner was not shared");
	lock = whole_file_lock(F_UNLCK);
	require(fcntl(state->fd, F_SETLK, &lock) == 0, "thread F_UNLCK");
	return NULL;
}

static void exercise_record_locks(void)
{
	const char *path = "/root/andock-record-locks";
	struct ThreadLockState thread_state;
	struct flock lock;
	pthread_t thread;
	pid_t child;
	int duplicate;
	int fd = open(path, O_CREAT | O_TRUNC | O_RDWR, 0600);
	if (fd < 0)
		fail("open record lock file");

	lock = whole_file_lock(F_WRLCK);
	require(fcntl(fd, F_SETLK, &lock) == 0, "parent F_SETLK");
	thread_state.fd = fd;
	require(pthread_create(&thread, NULL, observe_and_unlock_process_lock,
		&thread_state) == 0, "record lock pthread_create");
	require(pthread_join(thread, NULL) == 0, "record lock pthread_join");
	child_can_lock(fd, "thread unlock did not release process lock");

	lock = whole_file_lock(F_WRLCK);
	require(fcntl(fd, F_SETLK, &lock) == 0, "parent relock");
	child_observes_parent_lock(fd, true, "fork inherited or released lock");
	child_observes_parent_lock(fd, false, "child close released parent lock");
	duplicate = dup(fd);
	if (duplicate < 0)
		fail("record lock dup");
	require(close(duplicate) == 0, "record lock close duplicate");
	child_can_lock(fd, "closing duplicate did not release process locks");

	lock = whole_file_lock(F_WRLCK);
	require(fcntl(fd, F_SETLK, &lock) == 0, "explicit unlock setup");
	lock = whole_file_lock(F_WRLCK);
	require(fcntl(fd, F_GETLK, &lock) == 0 && lock.l_type == F_UNLCK,
		"owner F_GETLK saw its own lock");
	lock = whole_file_lock(F_UNLCK);
	require(fcntl(fd, F_SETLK, &lock) == 0, "explicit F_UNLCK");
	child_can_lock(fd, "explicit unlock did not release lock");

	child = fork();
	if (child < 0)
		fail("record lock teardown fork");
	if (child == 0) {
		lock = whole_file_lock(F_WRLCK);
		require(fcntl(fd, F_SETLK, &lock) == 0,
			"record lock teardown acquire");
		_exit(0);
	}
	wait_success(child, "record lock owner teardown");
	child_can_lock(fd, "process teardown leaked record lock");
	require(close(fd) == 0, "close record lock file");
	require(unlink(path) == 0, "unlink record lock file");
}

static void exec_check(int fd, bool closed)
{
	char descriptor[32];
	pid_t child;
	snprintf(descriptor, sizeof(descriptor), "%d", fd);
	child = fork();
	if (child < 0)
		fail("fork exec");
	if (child == 0) {
		execl(program_path, program_path,
			closed ? "--expect-closed" : "--send-fd", descriptor, NULL);
		_exit(127);
	}
	wait_success(child, "exec descriptor check");
}

static void exec_reuse_check(int fd)
{
	char descriptor[32];
	pid_t child;
	snprintf(descriptor, sizeof(descriptor), "%d", fd);
	child = fork();
	if (child < 0)
		fail("fork exec reuse");
	if (child == 0) {
		execl(program_path, program_path,
			"--expect-reusable", descriptor, NULL);
		_exit(127);
	}
	wait_success(child, "exec reusable descriptor check");
}

struct CloneExecState {
	int fd;
};

static int clone_exec_reuse(void *opaque)
{
	struct CloneExecState *state = opaque;
	char descriptor[32];
	snprintf(descriptor, sizeof(descriptor), "%d", state->fd);
	execl(program_path, program_path, "--expect-reusable", descriptor, NULL);
	return 127;
}

static void clone_files_exec_reuse_check(int fd)
{
	const size_t stack_size = 1024 * 1024;
	struct CloneExecState state = { .fd = fd };
	void *stack = malloc(stack_size);
	pid_t child;
	if (stack == NULL)
		fail("clone stack");
	child = clone(clone_exec_reuse, (char *) stack + stack_size,
		CLONE_FILES | SIGCHLD, &state);
	if (child < 0)
		fail("clone CLONE_FILES");
	wait_success(child, "CLONE_FILES child exec");
	free(stack);
}

static void exercise_regular_file_unshare_denial(void)
{
	int fd = open("/root/andock-unshare", O_CREAT | O_RDWR, 0600);
	if (fd < 0)
		fail("open regular unshare file");
	errno = 0;
	require(unshare(CLONE_FILES) < 0, "regular unshare unexpectedly succeeded");
	require(errno == EACCES || errno == EPERM, "regular unshare wrong errno");
	errno = 0;
	require(syscall(SYS_close_range, (unsigned int) fd, (unsigned int) fd,
		CLOSE_RANGE_UNSHARE) < 0,
		"regular close_range unshare unexpectedly succeeded");
	require(errno == EACCES || errno == EPERM,
		"regular close_range unshare wrong errno");
	require(fcntl(fd, F_GETFD) >= 0, "unshare denial closed regular file");
	close(fd);
	unlink("/root/andock-unshare");
}

static void exercise_clone_files_exec(void)
{
	const char *path = "/root/andock-clone-files";
	char content[7] = {};
	int fd = open(path, O_CREAT | O_TRUNC | O_RDWR | O_CLOEXEC, 0600);
	if (fd < 0)
		fail("open CLONE_FILES file");
	clone_files_exec_reuse_check(fd);
	require(fcntl(fd, F_GETFD) >= 0,
		"child exec pruned parent CLONE_FILES descriptor");
	require(write(fd, "parent", 6) == 6, "parent write after child exec");
	require(close(fd) == 0, "close CLONE_FILES file");
	fd = open(path, O_RDONLY);
	if (fd < 0)
		fail("reopen CLONE_FILES file");
	require(read(fd, content, 6) == 6 && memcmp(content, "parent", 6) == 0,
		"parent CLONE_FILES write did not persist");
	close(fd);
	unlink(path);
}

enum CloexecMethod {
	CLOEXEC_OPEN,
	CLOEXEC_SETFD,
	CLOEXEC_DUP3,
	CLOEXEC_F_DUPFD,
	CLOEXEC_CLOSE_RANGE,
};

static void exercise_regular_file_cloexec(enum CloexecMethod method)
{
	int flags = method == CLOEXEC_OPEN ? O_CLOEXEC : 0;
	int gap = open(
		"/root/andock-cloexec", O_CREAT | O_RDWR | flags, 0600);
	int target = open(
		"/root/andock-cloexec", O_CREAT | O_RDWR | flags, 0600);
	if (gap < 0 || target < 0)
		fail("open CLOEXEC descriptors");
	if (method == CLOEXEC_SETFD)
		require(fcntl(target, F_SETFD, FD_CLOEXEC) == 0,
			"F_SETFD CLOEXEC");
	else if (method == CLOEXEC_DUP3)
		require(dup3(gap, target, O_CLOEXEC) == target,
			"dup3 CLOEXEC");
	else if (method == CLOEXEC_F_DUPFD) {
		require(close(target) == 0, "prepare F_DUPFD_CLOEXEC");
		target = fcntl(gap, F_DUPFD_CLOEXEC, target);
		require(target >= 0, "F_DUPFD_CLOEXEC regular file");
	}
	else if (method == CLOEXEC_CLOSE_RANGE)
		require(syscall(SYS_close_range, (unsigned int) target,
			(unsigned int) target, CLOSE_RANGE_CLOEXEC) == 0,
			"close_range CLOEXEC regular file");
	exec_reuse_check(target);
	close(gap);
	close(target);
	unlink("/root/andock-cloexec");
}

struct RaceState {
	struct sockaddr_in address;
	atomic_bool stop;
};

static void *mutate_address(void *opaque)
{
	struct RaceState *state = opaque;
	struct in_addr public_address;
	struct in_addr private_address;
	inet_pton(AF_INET, "1.1.1.1", &public_address);
	inet_pton(AF_INET, "127.0.0.1", &private_address);
	while (!atomic_load_explicit(&state->stop, memory_order_relaxed)) {
		memcpy(&state->address.sin_addr, &public_address, sizeof(public_address));
		memcpy(&state->address.sin_addr, &private_address, sizeof(private_address));
	}
	return NULL;
}

static void exercise_address_race(int fd, uint16_t port)
{
	struct RaceState state = { .address = ipv4("1.1.1.1", port) };
	pthread_t mutator;
	char byte = 'r';
	struct iovec vector = { .iov_base = &byte, .iov_len = 1 };
	struct msghdr message = {
		.msg_name = &state.address,
		.msg_namelen = sizeof(state.address),
		.msg_iov = &vector,
		.msg_iovlen = 1,
	};
	struct mmsghdr messages[2] = {};
	for (size_t index = 0; index < 2; index++) {
		messages[index].msg_hdr = message;
	}
	atomic_init(&state.stop, false);
	require(pthread_create(&mutator, NULL, mutate_address, &state) == 0,
		"pthread_create");
	for (int iteration = 0; iteration < 1000; iteration++) {
		ssize_t result = sendto(fd, &byte, 1, 0,
			(struct sockaddr *) &state.address, sizeof(state.address));
		if (result < 0)
			require(errno == EACCES || errno == EPERM,
				"raced sendto wrong errno");
		else
			require(result == 1, "raced sendto wrong result");
		result = sendmsg(fd, &message, 0);
		if (result < 0)
			require(errno == EACCES || errno == EPERM,
				"raced sendmsg wrong errno");
		else
			require(result == 1, "raced sendmsg wrong result");
		result = sendmmsg(fd, messages, 2, 0);
		if (result < 0)
			require(errno == EACCES || errno == EPERM,
				"raced sendmmsg wrong errno");
		else
			require(result == 2, "raced sendmmsg wrong result");
	}
	atomic_store_explicit(&state.stop, true, memory_order_relaxed);
	require(pthread_join(mutator, NULL) == 0, "pthread_join");
}

static int descriptor_argument(const char *value)
{
	char *end;
	long descriptor = strtol(value, &end, 10);
	require(*value != '\0' && *end == '\0' && descriptor >= 0
		&& descriptor <= INT_MAX, "descriptor argument");
	return (int) descriptor;
}

int main(int argc, char **argv)
{
	int primary;
	int duplicate;
	int replacement;
	int race_port = 443;
	pid_t child;
	program_path = argv[0];
	if (argc == 2 && strcmp(argv[1], "--local-fd-policy") == 0) {
		expect_image_fd_policies();
		puts("ANDOCK_LOCAL_FD_POLICY_OK");
		return 0;
	}
	if (argc == 3 && strcmp(argv[1], "--expect-closed") == 0) {
		int fd = descriptor_argument(argv[2]);
		errno = 0;
		require(fcntl(fd, F_GETFD) < 0 && errno == EBADF,
			"CLOEXEC descriptor survived");
		return 0;
	}
	if (argc == 3 && strcmp(argv[1], "--send-fd") == 0) {
		send_public(descriptor_argument(argv[2]));
		return 0;
	}
	if (argc == 3 && strcmp(argv[1], "--expect-reusable") == 0) {
		int fd = descriptor_argument(argv[2]);
		int channels[64][2];
		int *channel = NULL;
		int peer;
		char byte = 'x';
		errno = 0;
		require(fcntl(fd, F_GETFD) < 0 && errno == EBADF,
			"CLOEXEC regular descriptor survived");
		for (size_t index = 0; index < 64; index++) {
			require(socketpair(AF_UNIX, SOCK_STREAM, 0, channels[index]) == 0,
				"socketpair after CLOEXEC");
			if (channels[index][0] == fd || channels[index][1] == fd) {
				channel = channels[index];
				break;
			}
			require(channels[index][1] < fd,
				"socketpair skipped reusable CLOEXEC descriptor");
		}
		require(channel != NULL,
			"socketpair did not reuse CLOEXEC descriptor");
		peer = channel[0] == fd ? channel[1] : channel[0];
		require(write(fd, &byte, 1) == 1,
			"write to reused CLOEXEC descriptor");
		byte = 0;
		require(read(peer, &byte, 1) == 1 && byte == 'x',
			"read from reused CLOEXEC descriptor");
		return 0;
	}
	if (argc == 3 && strcmp(argv[1], "--race-port") == 0) {
		race_port = descriptor_argument(argv[2]);
		require(race_port > 0 && race_port <= UINT16_MAX, "race port");
	}
	else
		require(argc == 1, "usage");

	exercise_regular_file_unshare_denial();
	expect_image_fd_policies();
	exercise_umask_semantics();
	exercise_unix_socket_lifecycle();
	exercise_unix_bind_race();
	exercise_unix_socket_aliases();
	exercise_failed_unix_bind_retry();
	primary = udp_socket();
	exercise_record_locks();
	for (int method = CLOEXEC_OPEN; method <= CLOEXEC_CLOSE_RANGE; method++)
		exercise_regular_file_cloexec((enum CloexecMethod) method);
	exercise_clone_files_exec();
	send_public(primary);
	send_public_message(primary);
	send_public_messages(primary);
	expect_sendmmsg_multi_peer_denied(primary);
	expect_sendmmsg_atomic_denial(primary);
	expect_denied_private(primary);
	expect_scm_rights_denied(primary);
	exercise_address_race(primary, (uint16_t) race_port);
	exercise_ipv6();
	exercise_ephemeral_udp_bind();
	expect_udp_receive_without_peer_denied();
	exercise_unconnected_udp_reply_peer();
	expect_udp_disconnect_denied();
	expect_dangerous_socket_denied(
		AF_NETLINK, SOCK_RAW, NETLINK_ROUTE, "AF_NETLINK");
	expect_dangerous_socket_denied(
		AF_PACKET, SOCK_RAW, htons(ETH_P_ALL), "AF_PACKET");
	expect_dangerous_socket_denied(
		AF_INET, SOCK_RAW, IPPROTO_ICMP, "IPv4 raw");
	expect_dangerous_socket_denied(
		AF_INET6, SOCK_RAW, IPPROTO_ICMPV6, "IPv6 raw");

	duplicate = dup(primary);
	if (duplicate < 0)
		fail("dup");
	close(primary);
	send_public(duplicate);

	replacement = udp_socket();
	require(dup2(duplicate, replacement) == replacement, "dup2");
	close(duplicate);
	send_public(replacement);

	child = fork();
	if (child < 0)
		fail("fork");
	if (child == 0) {
		send_public(replacement);
		_exit(0);
	}
	wait_success(child, "fork descriptor inheritance");

	duplicate = fcntl(replacement, F_DUPFD, 64);
	if (duplicate < 0)
		fail("F_DUPFD");
	exec_check(duplicate, false);
	close(duplicate);
	duplicate = fcntl(replacement, F_DUPFD_CLOEXEC, 64);
	if (duplicate < 0)
		fail("F_DUPFD_CLOEXEC");
	exec_check(duplicate, true);
	close(duplicate);

	duplicate = dup(replacement);
	if (duplicate < 0)
		fail("dup close_range");
	require(syscall(SYS_close_range, (unsigned int) duplicate,
		(unsigned int) duplicate, 0) == 0, "close_range");
	errno = 0;
	require(fcntl(duplicate, F_GETFD) < 0 && errno == EBADF,
		"close_range did not close");
	errno = 0;
	require(syscall(SYS_close_range, (unsigned int) replacement,
		(unsigned int) replacement, CLOSE_RANGE_UNSHARE) < 0,
		"close_range unshare unexpectedly succeeded");
	require(errno == EPERM || errno == EACCES,
		"close_range unshare wrong errno");

	duplicate = dup(replacement);
	if (duplicate < 0)
		fail("dup close_range cloexec");
	require(syscall(SYS_close_range, (unsigned int) duplicate,
		(unsigned int) duplicate, CLOSE_RANGE_CLOEXEC) == 0,
		"close_range cloexec");
	exec_check(duplicate, true);
	close(duplicate);

	errno = 0;
	require(syscall(SYS_unshare, CLONE_FILES) < 0,
		"unshare CLONE_FILES unexpectedly succeeded");
	require(errno == EPERM || errno == EACCES, "unshare wrong errno");
	errno = 0;
	require(syscall(SYS_pidfd_getfd, -1, replacement, 0) < 0
		&& errno == EPERM, "pidfd_getfd not denied");
	errno = 0;
	require(syscall(SYS_io_uring_setup, 1, NULL) < 0,
		"io_uring_setup unexpectedly succeeded");
	/* Android's inherited app seccomp filter can reject io_uring before
	 * PRoot's later filter observes it.  Both outcomes make the escape
	 * surface unavailable; Andock itself returns EPERM when it is reached. */
	require(errno == EPERM || errno == ENOSYS,
		"io_uring_setup wrong errno");

	struct sockaddr_in connected = ipv4("1.1.1.1", 443);
	require(connect(replacement, (struct sockaddr *) &connected,
		sizeof(connected)) == 0, "UDP connect");
	require(write(replacement, "c", 1) == 1, "connected write");
	struct sockaddr unspec = { .sa_family = AF_UNSPEC };
	errno = 0;
	require(connect(replacement, &unspec, sizeof(unspec)) < 0,
		"UDP disconnect unexpectedly succeeded");
	require(errno == EACCES || errno == EPERM,
		"UDP disconnect wrong errno");
	require(write(replacement, "d", 1) == 1,
		"denied disconnect altered connected socket");
	close(replacement);

	puts("ANDOCK_NETWORK_SYSCALLS_OK");
	return 0;
}
