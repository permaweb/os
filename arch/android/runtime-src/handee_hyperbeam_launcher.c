#include <dirent.h>
#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

typedef struct {
    char **items;
    size_t len;
    size_t cap;
} argvec_t;

static const char *arg_value(int argc, char **argv, const char *name) {
    for (int i = 1; i + 1 < argc; i++) {
        if (strcmp(argv[i], name) == 0) {
            return argv[i + 1];
        }
    }
    return "";
}

static int readable_file(const char *path) {
    return path != NULL && path[0] != '\0' && access(path, R_OK) == 0;
}

static int directory_exists(const char *path) {
    struct stat st;
    return path != NULL && stat(path, &st) == 0 && S_ISDIR(st.st_mode);
}

static char *xstrdup(const char *value) {
    char *copy = strdup(value);
    if (copy == NULL) {
        perror("strdup");
        exit(70);
    }
    return copy;
}

static char *path_join(const char *left, const char *right) {
    size_t left_len = strlen(left);
    size_t right_len = strlen(right);
    int needs_slash = left_len > 0 && left[left_len - 1] != '/';
    char *out = malloc(left_len + (size_t)needs_slash + right_len + 1);
    if (out == NULL) {
        perror("malloc");
        exit(70);
    }
    memcpy(out, left, left_len);
    if (needs_slash) {
        out[left_len] = '/';
    }
    memcpy(out + left_len + (size_t)needs_slash, right, right_len);
    out[left_len + (size_t)needs_slash + right_len] = '\0';
    return out;
}

static char *dirname_copy(const char *path) {
    char *copy = xstrdup(path);
    char *slash = strrchr(copy, '/');
    if (slash == NULL) {
        free(copy);
        return xstrdup(".");
    }
    if (slash == copy) {
        slash[1] = '\0';
    } else {
        *slash = '\0';
    }
    return copy;
}

static void mkdir_p(const char *path) {
    char *tmp = xstrdup(path);
    for (char *p = tmp + 1; *p; p++) {
        if (*p == '/') {
            *p = '\0';
            if (mkdir(tmp, 0700) != 0 && errno != EEXIST) {
                fprintf(stderr, "mkdir failed for %s: %s\n", tmp, strerror(errno));
                exit(73);
            }
            *p = '/';
        }
    }
    if (mkdir(tmp, 0700) != 0 && errno != EEXIST) {
        fprintf(stderr, "mkdir failed for %s: %s\n", tmp, strerror(errno));
        exit(73);
    }
    free(tmp);
}

static void mkdir_parent(const char *path) {
    char *copy = xstrdup(path);
    char *slash = strrchr(copy, '/');
    if (slash != NULL) {
        *slash = '\0';
        mkdir_p(copy);
    }
    free(copy);
}

static void replace_symlink(const char *target, const char *link_path) {
    mkdir_parent(link_path);
    unlink(link_path);
    if (symlink(target, link_path) != 0) {
        fprintf(stderr, "symlink %s -> %s failed: %s\n",
            link_path, target, strerror(errno));
        exit(73);
    }
}

static void args_add(argvec_t *args, char *value) {
    if (args->len + 1 >= args->cap) {
        size_t next = args->cap == 0 ? 32 : args->cap * 2;
        char **items = realloc(args->items, next * sizeof(char *));
        if (items == NULL) {
            perror("realloc");
            exit(70);
        }
        args->items = items;
        args->cap = next;
    }
    args->items[args->len++] = value;
    args->items[args->len] = NULL;
}

static void add_ebin_dirs(argvec_t *args, const char *lib_dir) {
    DIR *dir = opendir(lib_dir);
    if (dir == NULL) {
        fprintf(stderr, "cannot open Erlang lib dir %s: %s\n", lib_dir, strerror(errno));
        exit(72);
    }
    struct dirent *entry;
    while ((entry = readdir(dir)) != NULL) {
        if (entry->d_name[0] == '.') {
            continue;
        }
        char *app_dir = path_join(lib_dir, entry->d_name);
        char *ebin_dir = path_join(app_dir, "ebin");
        if (directory_exists(ebin_dir)) {
            args_add(args, xstrdup("-pa"));
            args_add(args, ebin_dir);
        } else {
            free(ebin_dir);
        }
        free(app_dir);
    }
    closedir(dir);
}

static char *find_child_dir(const char *root, const char *prefix) {
    DIR *dir = opendir(root);
    if (dir == NULL) {
        fprintf(stderr, "cannot open %s: %s\n", root, strerror(errno));
        exit(72);
    }
    struct dirent *entry;
    while ((entry = readdir(dir)) != NULL) {
        if (entry->d_name[0] == '.') {
            continue;
        }
        if (strncmp(entry->d_name, prefix, strlen(prefix)) != 0) {
            continue;
        }
        char *candidate = path_join(root, entry->d_name);
        if (directory_exists(candidate)) {
            closedir(dir);
            return candidate;
        }
        free(candidate);
    }
    closedir(dir);
    fprintf(stderr, "no %s* directory found under %s\n", prefix, root);
    exit(72);
}

static char *find_erts_bin(const char *erlang_root) {
    char *erts_dir = find_child_dir(erlang_root, "erts-");
    char *bin_dir = path_join(erts_dir, "bin");
    free(erts_dir);
    return bin_dir;
}

static char *find_boot_script(const char *erlang_root) {
    char *releases_dir = path_join(erlang_root, "releases");
    char *release_dir = find_child_dir(releases_dir, "");
    char *boot_file = path_join(release_dir, "start_clean.boot");
    if (!readable_file(boot_file)) {
        free(boot_file);
        boot_file = path_join(release_dir, "start.boot");
    }
    if (!readable_file(boot_file)) {
        fprintf(stderr, "no boot script found under %s\n", release_dir);
        exit(72);
    }
    boot_file[strlen(boot_file) - strlen(".boot")] = '\0';
    free(release_dir);
    free(releases_dir);
    return boot_file;
}

static void link_native_payloads(const char *root, const char *native_dir, const char *abi) {
    char *native_links_dir = path_join(root, "native-links");
    char *filename = malloc(strlen(abi) + strlen(".txt") + 1);
    if (filename == NULL) {
        perror("malloc");
        exit(70);
    }
    sprintf(filename, "%s.txt", abi);
    char *manifest = path_join(native_links_dir, filename);
    FILE *file = fopen(manifest, "r");
    if (file == NULL) {
        fprintf(stderr, "cannot open native link manifest %s: %s\n",
            manifest, strerror(errno));
        exit(72);
    }

    char line[4096];
    while (fgets(line, sizeof(line), file) != NULL) {
        char *newline = strchr(line, '\n');
        if (newline) {
            *newline = '\0';
        }
        if (line[0] == '\0' || line[0] == '#') {
            continue;
        }
        char *sep = strchr(line, '|');
        if (sep == NULL) {
            fprintf(stderr, "bad native link manifest line: %s\n", line);
            exit(72);
        }
        *sep = '\0';
        char *rel_path = line;
        char *native_name = sep + 1;
        char *target = path_join(native_dir, native_name);
        char *link_path = path_join(root, rel_path);
        if (access(target, R_OK) != 0) {
            fprintf(stderr, "missing native payload %s\n", target);
            exit(72);
        }
        replace_symlink(target, link_path);
        free(target);
        free(link_path);
    }
    fclose(file);
    free(native_links_dir);
    free(filename);
    free(manifest);
}

static void set_path_env(const char *bindir, const char *erlang_root) {
    const char *old_path = getenv("PATH");
    const char *suffix = old_path && old_path[0] != '\0' ? old_path : "/system/bin";
    char *root_bin = path_join(erlang_root, "bin");
    size_t size = strlen(bindir) + strlen(root_bin) + strlen(suffix) + 3;
    char *path = malloc(size);
    if (path == NULL) {
        perror("malloc");
        exit(70);
    }
    snprintf(path, size, "%s:%s:%s", bindir, root_bin, suffix);
    setenv("PATH", path, 1);
    free(root_bin);
    free(path);
}

static const char *relative_to_root(const char *root, const char *path) {
    size_t root_len = strlen(root);
    if (strncmp(root, path, root_len) == 0 && path[root_len] == '/') {
        return path + root_len + 1;
    }
    return path;
}

int main(int argc, char **argv) {
    const char *root = arg_value(argc, argv, "--root");
    const char *config = arg_value(argc, argv, "--config");
    const char *abi = getenv("HANDEE_ANDROID_ABI");
    const char *native_env = getenv("HANDEE_NATIVE_LIB_DIR");
    const char *crypto_socket = getenv("HANDEE_CRYPTO_SOCKET");
    char *native_dir = native_env && native_env[0] != '\0'
        ? xstrdup(native_env)
        : dirname_copy(argv[0]);

    if (root[0] == '\0') {
        fprintf(stderr, "--root is required\n");
        return 64;
    }
    if (!readable_file(config)) {
        fprintf(stderr, "config is not readable: %s: %s\n", config, strerror(errno));
        return 64;
    }
    if (abi == NULL || abi[0] == '\0') {
        fprintf(stderr, "HANDEE_ANDROID_ABI is required\n");
        return 64;
    }

    char *erlang_dir = path_join(root, "erlang");
    char *erlang_root = path_join(erlang_dir, abi);
    char *lib_dir = path_join(erlang_root, "lib");
    char *bindir = find_erts_bin(erlang_root);
    char *erlexec = path_join(bindir, "erlexec");
    char *boot_script = find_boot_script(erlang_root);
    char *home = path_join(root, "home");
    const char *hb_config = relative_to_root(root, config);
    mkdir_p(home);

    link_native_payloads(root, native_dir, abi);

    if (chdir(root) != 0) {
        fprintf(stderr, "chdir failed for %s: %s\n", root, strerror(errno));
        return 72;
    }

    setenv("ROOTDIR", erlang_root, 1);
    setenv("BINDIR", bindir, 1);
    setenv("EMU", "beam", 1);
    setenv("PROGNAME", "erl", 1);
    setenv("HB_CONFIG", hb_config, 1);
    setenv("HANDEE_RUNTIME_ROOT", root, 1);
    setenv("HOME", home, 1);
    setenv("ERL_LIBS", lib_dir, 1);
    set_path_env(bindir, erlang_root);

    argvec_t args = {0};
    args_add(&args, erlexec);
    args_add(&args, xstrdup("-boot"));
    args_add(&args, boot_script);
    args_add(&args, xstrdup("+S"));
    args_add(&args, xstrdup("2:2"));
    args_add(&args, xstrdup("-noshell"));
    args_add(&args, xstrdup("-noinput"));
    args_add(&args, xstrdup("-start_epmd"));
    args_add(&args, xstrdup("false"));
    add_ebin_dirs(&args, lib_dir);
    args_add(&args, xstrdup("-eval"));
    args_add(&args, xstrdup("handee_bootstrap:start()."));

    fprintf(stdout, "handee-native-launcher=exec-erlexec\n");
    fprintf(stdout, "runtime-root=%s\n", root);
    fprintf(stdout, "erlang-root=%s\n", erlang_root);
    fprintf(stdout, "bindir=%s\n", bindir);
    fprintf(stdout, "config=%s\n", config);
    fprintf(stdout, "android-abi=%s\n", abi);
    fprintf(stdout, "crypto-socket=%s\n", crypto_socket ? crypto_socket : "");
    fflush(stdout);

    execv(erlexec, args.items);
    fprintf(stderr, "execv failed for %s: %s\n", erlexec, strerror(errno));
    return 74;
}
