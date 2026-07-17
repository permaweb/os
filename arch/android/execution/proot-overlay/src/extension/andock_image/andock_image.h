#ifndef ANDOCK_IMAGE_H
#define ANDOCK_IMAGE_H

#include <stdbool.h>
#include <limits.h>
#include <sys/socket.h>
#include <sys/un.h>

#include "extension/extension.h"

extern bool andock_image_enabled(void);
extern bool andock_image_is_kernel_path(const char *path);
extern int andock_image_open_host_path(const char *path, int flags);
extern int andock_image_translate_path(Tracee *tracee, char result[PATH_MAX],
		int dir_fd, const char *user_path, bool deref_final);
extern int andock_image_translate_executable_path(Tracee *tracee,
		char result[PATH_MAX], int dir_fd, const char *user_path,
		bool deref_final);
extern int andock_image_find_executable(Tracee *tracee,
		char result[PATH_MAX], const char *paths, const char *command);
extern int andock_image_take_executable_path(Tracee *tracee,
		char result[PATH_MAX]);
extern int andock_image_translate_unix_socket(Tracee *tracee,
		struct sockaddr_un *address, const char *user_path);
extern int andock_image_detranslate_unix_socket(Tracee *tracee,
		const struct sockaddr_un *address, socklen_t size,
		char result[PATH_MAX]);
extern int andock_image_callback(Extension *extension, ExtensionEvent event,
		intptr_t data1, intptr_t data2);

#endif
