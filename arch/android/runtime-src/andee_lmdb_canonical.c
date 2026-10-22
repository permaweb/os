/* Offline, ordered rebuild of the preload's single unnamed database. */
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>
#include "lmdb.h"

static void check(int rc)
{
    if (rc != MDB_SUCCESS) {
        fprintf(stderr, "LMDB canonicalization: %s\n", mdb_strerror(rc));
        exit(EXIT_FAILURE);
    }
}

int main(int argc, char **argv)
{
    MDB_env *source, *target;
    MDB_envinfo info;
    MDB_txn *read, *write;
    MDB_dbi source_db, target_db;
    MDB_cursor *cursor;
    MDB_val key, value;
    unsigned int flags;
    int rc;

    if (argc != 3) {
        fprintf(stderr, "usage: %s source fresh-destination\n", argv[0]);
        return EXIT_FAILURE;
    }
    if (mkdir(argv[2], 0700) != 0) {
        perror("fresh canonical destination");
        return EXIT_FAILURE;
    }
    check(mdb_env_create(&source));
    check(mdb_env_open(source, argv[1], MDB_RDONLY | MDB_NOLOCK, 0));
    check(mdb_env_info(source, &info));
    check(mdb_txn_begin(source, NULL, MDB_RDONLY, &read));
    check(mdb_dbi_open(read, NULL, 0, &source_db));
    check(mdb_dbi_flags(read, source_db, &flags));
    if (flags != 0) {
        fprintf(stderr, "preload requires an ordinary unnamed database\n");
        return EXIT_FAILURE;
    }
    check(mdb_env_create(&target));
    check(mdb_env_set_mapsize(target, info.me_mapsize));
    check(mdb_env_open(target, argv[2], MDB_NOLOCK, 0600));
    check(mdb_txn_begin(target, NULL, 0, &write));
    check(mdb_dbi_open(write, NULL, MDB_CREATE, &target_db));
    check(mdb_cursor_open(read, source_db, &cursor));
    while ((rc = mdb_cursor_get(cursor, &key, &value, MDB_NEXT)) == MDB_SUCCESS)
        check(mdb_put(write, target_db, &key, &value, MDB_APPEND));
    if (rc != MDB_NOTFOUND)
        check(rc);
    mdb_cursor_close(cursor);
    mdb_txn_abort(read);
    check(mdb_txn_commit(write));
    check(mdb_env_sync(target, 1));
    mdb_env_close(target);
    mdb_env_close(source);
    return EXIT_SUCCESS;
}
