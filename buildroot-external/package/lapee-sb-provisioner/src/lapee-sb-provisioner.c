/*
 * LapEE Secure Boot provisioner.
 *
 * Runs only in the dedicated lapee.mode=sb-provision image. It writes
 * operator-owned public Secure Boot enrollment artifacts from the boot ESP
 * into firmware variables while the machine is in UEFI Setup Mode.
 */

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define EFI_GLOBAL_GUID "8be4df61-93ca-11d2-aa0d-00e098032b8c"
#define EFI_IMAGE_SECURITY_DB_GUID "d719b2cb-3d3a-4596-a3bc-dad00e67656f"
#define EFI_SECURE_BOOT_ENABLE_DISABLE_GUID "f0a30bc7-af08-4556-99c4-001009c93a44"
#define EFI_CUSTOM_MODE_ENABLE_GUID "c076ec0c-7028-4399-a072-71ee5c448b9f"

#define EFI_VARIABLE_NON_VOLATILE 0x00000001U
#define EFI_VARIABLE_BOOTSERVICE_ACCESS 0x00000002U
#define EFI_VARIABLE_RUNTIME_ACCESS 0x00000004U
#define EFI_VARIABLE_TIME_BASED_AUTHENTICATED_WRITE_ACCESS 0x00000020U

static const uint32_t secure_var_attrs =
	EFI_VARIABLE_NON_VOLATILE |
	EFI_VARIABLE_BOOTSERVICE_ACCESS |
	EFI_VARIABLE_RUNTIME_ACCESS |
	EFI_VARIABLE_TIME_BASED_AUTHENTICATED_WRITE_ACCESS;

static const uint32_t plain_setup_var_attrs =
	EFI_VARIABLE_NON_VOLATILE |
	EFI_VARIABLE_BOOTSERVICE_ACCESS;

static void die(const char *msg)
{
	perror(msg);
	exit(1);
}

static void *read_file(const char *path, size_t *len)
{
	struct stat st;
	uint8_t *buf;
	int fd;
	ssize_t got;
	size_t off = 0;

	fd = open(path, O_RDONLY | O_CLOEXEC);
	if (fd < 0)
		die(path);
	if (fstat(fd, &st) < 0)
		die("fstat");
	if (st.st_size <= 0 || st.st_size > (16 * 1024 * 1024)) {
		fprintf(stderr, "refusing suspicious input size for %s: %lld\n",
			path, (long long)st.st_size);
		exit(1);
	}
	buf = malloc((size_t)st.st_size);
	if (!buf)
		die("malloc");
	while (off < (size_t)st.st_size) {
		got = read(fd, buf + off, (size_t)st.st_size - off);
		if (got < 0)
			die("read");
		if (got == 0)
			break;
		off += (size_t)got;
	}
	close(fd);
	if (off != (size_t)st.st_size) {
		fprintf(stderr, "short read for %s\n", path);
		exit(1);
	}
	*len = off;
	return buf;
}

static int read_one_byte_var(const char *efivars, const char *name, const char *guid)
{
	char path[PATH_MAX];
	uint8_t data[5];
	int fd;
	ssize_t got;

	snprintf(path, sizeof(path), "%s/%s-%s", efivars, name, guid);
	fd = open(path, O_RDONLY | O_CLOEXEC);
	if (fd < 0)
		return -1;
	got = read(fd, data, sizeof(data));
	close(fd);
	if (got < 5)
		return -1;
	return data[4];
}

static uint32_t read_var_attrs_or(const char *efivars, const char *name,
				  const char *guid, uint32_t fallback)
{
	char path[PATH_MAX];
	uint8_t data[4];
	int fd;
	ssize_t got;

	snprintf(path, sizeof(path), "%s/%s-%s", efivars, name, guid);
	fd = open(path, O_RDONLY | O_CLOEXEC);
	if (fd < 0)
		return fallback;
	got = read(fd, data, sizeof(data));
	close(fd);
	if (got < (ssize_t)sizeof(data))
		return fallback;
	return (uint32_t)data[0] |
	       ((uint32_t)data[1] << 8) |
	       ((uint32_t)data[2] << 16) |
	       ((uint32_t)data[3] << 24);
}

static int var_has_payload(const char *efivars, const char *name, const char *guid)
{
	char path[PATH_MAX];
	uint8_t data[5];
	int fd;
	ssize_t got;

	snprintf(path, sizeof(path), "%s/%s-%s", efivars, name, guid);
	fd = open(path, O_RDONLY | O_CLOEXEC);
	if (fd < 0)
		return 0;
	got = read(fd, data, sizeof(data));
	close(fd);
	return got >= (ssize_t)sizeof(data);
}

static void write_var(const char *efivars, const char *name, const char *guid,
		      const void *payload, size_t payload_len)
{
	char path[PATH_MAX];
	uint8_t *buf;
	size_t len = sizeof(uint32_t) + payload_len;
	int fd;

	snprintf(path, sizeof(path), "%s/%s-%s", efivars, name, guid);
	fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
	if (fd < 0)
		die(path);

	buf = malloc(len);
	if (!buf)
		die("malloc");
	buf[0] = (uint8_t)(secure_var_attrs & 0xff);
	buf[1] = (uint8_t)((secure_var_attrs >> 8) & 0xff);
	buf[2] = (uint8_t)((secure_var_attrs >> 16) & 0xff);
	buf[3] = (uint8_t)((secure_var_attrs >> 24) & 0xff);
	memcpy(buf + sizeof(uint32_t), payload, payload_len);
	if (write(fd, buf, len) != (ssize_t)len)
		die("write variable");
	if (fsync(fd) < 0 && errno != EINVAL)
		die("fsync");
	free(buf);
	close(fd);
}

static int write_one_byte_var(const char *efivars, const char *name,
			      const char *guid, uint8_t value)
{
	char path[PATH_MAX];
	uint8_t buf[5];
	uint32_t attrs;
	int fd;
	ssize_t written;

	attrs = read_var_attrs_or(efivars, name, guid, plain_setup_var_attrs);
	snprintf(path, sizeof(path), "%s/%s-%s", efivars, name, guid);
	fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
	if (fd < 0)
		return -errno;
	buf[0] = (uint8_t)(attrs & 0xff);
	buf[1] = (uint8_t)((attrs >> 8) & 0xff);
	buf[2] = (uint8_t)((attrs >> 16) & 0xff);
	buf[3] = (uint8_t)((attrs >> 24) & 0xff);
	buf[4] = value;
	written = write(fd, buf, sizeof(buf));
	if (written != (ssize_t)sizeof(buf)) {
		int err = errno ? -errno : -EIO;
		close(fd);
		return err;
	}
	if (fsync(fd) < 0 && errno != EINVAL) {
		int err = -errno;
		close(fd);
		return err;
	}
	close(fd);
	return 0;
}

static void request_secure_boot_enable(const char *efivars)
{
	int rc;

	rc = write_one_byte_var(efivars, "CustomMode",
				EFI_CUSTOM_MODE_ENABLE_GUID, 0);
	if (rc == 0)
		printf("requested CustomMode=0 (standard Secure Boot mode)\n");
	else
		printf("could not set CustomMode=0: %s\n", strerror(-rc));

	rc = write_one_byte_var(efivars, "SecureBootEnable",
				EFI_SECURE_BOOT_ENABLE_DISABLE_GUID, 1);
	if (rc == 0)
		printf("requested SecureBootEnable=1\n");
	else
		printf("could not set SecureBootEnable=1: %s\n", strerror(-rc));
}

static void enroll_auth(const char *efivars, const char *root,
			const char *var, const char *guid, const char *file)
{
	char path[PATH_MAX];
	void *auth;
	size_t auth_len;

	snprintf(path, sizeof(path), "%s/%s", root, file);
	printf("enrolling %s from %s\n", var, path);
	auth = read_file(path, &auth_len);
	write_var(efivars, var, guid, auth, auth_len);
	free(auth);
	printf("enrolled %s\n", var);
}

int main(int argc, char **argv)
{
	const char *efivars = argc > 1 ? argv[1] : "/sys/firmware/efi/efivars";
	const char *root = argc > 2 ? argv[2] : "/mnt/esp";
	int setup_mode, secure_boot;

	setup_mode = read_one_byte_var(efivars, "SetupMode", EFI_GLOBAL_GUID);
	secure_boot = read_one_byte_var(efivars, "SecureBoot", EFI_GLOBAL_GUID);
	printf("SetupMode=%d SecureBoot=%d\n", setup_mode, secure_boot);
	if (setup_mode != 1) {
		if (var_has_payload(efivars, "db", EFI_IMAGE_SECURITY_DB_GUID) &&
		    var_has_payload(efivars, "KEK", EFI_GLOBAL_GUID) &&
		    var_has_payload(efivars, "PK", EFI_GLOBAL_GUID)) {
			printf("Secure Boot variables are already populated; skipping key enrollment.\n");
			if (secure_boot != 1)
				request_secure_boot_enable(efivars);
			setup_mode = read_one_byte_var(efivars, "SetupMode", EFI_GLOBAL_GUID);
			secure_boot = read_one_byte_var(efivars, "SecureBoot", EFI_GLOBAL_GUID);
			printf("finished. SetupMode=%d SecureBoot=%d\n", setup_mode, secure_boot);
			printf("power off, enable Secure Boot if needed, then boot the signed LapEE USB image.\n");
			return 0;
		}
		fprintf(stderr,
			"refusing to enroll keys: firmware is not in Setup Mode\n");
		return 2;
	}

	enroll_auth(efivars, root, "db", EFI_IMAGE_SECURITY_DB_GUID, "db.auth");
	enroll_auth(efivars, root, "KEK", EFI_GLOBAL_GUID, "KEK.auth");
	enroll_auth(efivars, root, "PK", EFI_GLOBAL_GUID, "PK.auth");
	request_secure_boot_enable(efivars);

	setup_mode = read_one_byte_var(efivars, "SetupMode", EFI_GLOBAL_GUID);
	secure_boot = read_one_byte_var(efivars, "SecureBoot", EFI_GLOBAL_GUID);
	printf("finished. SetupMode=%d SecureBoot=%d\n", setup_mode, secure_boot);
	if (!var_has_payload(efivars, "db", EFI_IMAGE_SECURITY_DB_GUID) ||
	    !var_has_payload(efivars, "KEK", EFI_GLOBAL_GUID) ||
	    !var_has_payload(efivars, "PK", EFI_GLOBAL_GUID)) {
		fprintf(stderr,
			"enrollment writes returned but enrolled variables were not readable\n");
		return 3;
	}
	if (setup_mode == 1) {
		printf("firmware still reports SetupMode=1 after enrollment.\n");
		printf("some machines leave Setup Mode only after a power cycle.\n");
	}
	printf("power off, enable Secure Boot if needed, then boot the signed LapEE USB image.\n");
	return 0;
}
