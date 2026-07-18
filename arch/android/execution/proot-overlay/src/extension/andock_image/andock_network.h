#ifndef ANDOCK_NETWORK_H
#define ANDOCK_NETWORK_H

#include <stdbool.h>
#include <sys/socket.h>

int andock_network_start(int fd);
void andock_network_stop(void);
bool andock_network_enabled(void);
int andock_network_create_socket(int family, int type, int protocol, int *fd);
int andock_network_authorize(const struct sockaddr *address,
		socklen_t address_size, int transport);
int andock_network_drain_udp(int fd);
int andock_network_lock_udp_peer(int fd, const struct sockaddr *address,
		socklen_t address_size);

#endif
