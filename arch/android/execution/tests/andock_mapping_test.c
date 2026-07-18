#include <dirent.h>
#include <errno.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

#include "extension/andock_image/andock_mapping.h"

static unsigned int active_references;
static unsigned int active_writable;
static unsigned int retains;
static unsigned int releases;

static void fail(const char *label)
{
	fprintf(stderr, "%s failed\n", label);
	exit(1);
}

static int retain_mapping(uint64_t cache_id, bool writable)
{
	if (cache_id == 0)
		return -EINVAL;
	active_references++;
	active_writable += writable ? 1 : 0;
	retains++;
	return 0;
}

static int release_mapping(uint64_t cache_id, bool writable)
{
	if (cache_id == 0 || active_references == 0
	    || (writable && active_writable == 0))
		return -EINVAL;
	active_references--;
	active_writable -= writable ? 1 : 0;
	releases++;
	return 0;
}

static const struct AndockMappingOps ops = {
	.retain = retain_mapping,
	.release = release_mapping,
};

static long resident_pages(void)
{
	FILE *status = fopen("/proc/self/statm", "r");
	long total = 0;
	long resident = 0;
	if (status == NULL || fscanf(status, "%ld %ld", &total, &resident) != 2)
		fail("resident-pages");
	fclose(status);
	return resident;
}

static int descriptor_count(void)
{
	DIR *directory = opendir("/proc/self/fd");
	if (directory == NULL)
		fail("descriptor-directory");
	int count = 0;
	while (readdir(directory) != NULL)
		count++;
	closedir(directory);
	return count;
}

static void expect_state(const char *label, struct AndockMappingTable *table,
		size_t count, unsigned int references, unsigned int writable)
{
	if (andock_mapping_count(table) != count
	    || active_references != references
	    || active_writable != writable)
		fail(label);
}

int main(void)
{
	struct AndockMappingTable *table = andock_mapping_table_new(&ops);
	if (table == NULL)
		fail("new");

	/* A failed mmap never reaches replace and therefore owns no cache state. */
	expect_state("failed-mmap", table, 0, 0, 0);
	int initial_fds = descriptor_count();
	long initial_rss = resident_pages();
	for (unsigned int iteration = 0; iteration < 20000; iteration++) {
		if (andock_mapping_replace(table, 0x100000, 4096, 1, true, true) < 0
		    || andock_mapping_unmap(table, 0x100000, 4096) < 0)
			fail("repeated-map-unmap");
	}
	expect_state("repeated-map-unmap-state", table, 0, 0, 0);
	if (descriptor_count() != initial_fds)
		fail("descriptor-bound");
	if (getenv("ASAN_OPTIONS") == NULL
	    && resident_pages() > initial_rss + 256)
		fail("resident-bound");

	if (andock_mapping_replace(table, 0x200000, 0x4000, 2, false, true) < 0
	    || andock_mapping_unmap(table, 0x201000, 0x1000) < 0)
		fail("partial-unmap");
	expect_state("partial-unmap-state", table, 2, 2, 0);
	if (andock_mapping_protect(table, 0x202000, 0x2000, true) < 0)
		fail("partial-protect");
	expect_state("partial-protect-state", table, 2, 2, 1);
	if (andock_mapping_unmap(table, 0x200000, 0x1000) < 0
	    || andock_mapping_unmap(table, 0x202000, 0x2000) < 0)
		fail("partial-release");
	expect_state("partial-release-state", table, 0, 0, 0);

	if (andock_mapping_replace(table, 0x300000, 0x3000, 3, true, true) < 0
	    || andock_mapping_remap(table, 0x300000, 0x3000,
		0x400000, 0x5000, false) < 0)
		fail("move-expand");
	expect_state("move-expand-state", table, 1, 1, 1);
	if (andock_mapping_unmap(table, 0x300000, 0x3000) < 0)
		fail("old-range-absent");
	expect_state("old-range-absent-state", table, 1, 1, 1);
	if (andock_mapping_remap(table, 0x400000, 0x5000,
		0x400000, 0x2000, false) < 0)
		fail("in-place-shrink");
	expect_state("in-place-shrink-state", table, 1, 1, 1);
	if (andock_mapping_unmap(table, 0x400000, 0x2000) < 0)
		fail("shrink-release");

	if (andock_mapping_replace(table, 0x500000, 0x2000, 4, true, true) < 0
	    || andock_mapping_remap(table, 0x500000, 0x2000,
		0x600000, 0x2000, true) < 0)
		fail("dontunmap");
	expect_state("dontunmap-state", table, 2, 2, 2);
	if (andock_mapping_unmap(table, 0x500000, 0x2000) < 0)
		fail("dontunmap-old-release");
	expect_state("dontunmap-old-release-state", table, 1, 1, 1);
	if (andock_mapping_replace(table, 0x700000, 0x2000, 5,
		false, false) < 0)
		fail("read-only-map");
	if (andock_mapping_write_allowed(table, 0x700000, 0x1000) != 0
	    || andock_mapping_protect(table, 0x700000, 0x1000, true) != -EACCES)
		fail("read-only-upgrade");
	if (andock_mapping_unmap(table, 0x700000, 0x2000) < 0)
		fail("read-only-unmap");

	struct AndockMappingTable *forked = andock_mapping_table_clone(table);
	if (forked == NULL)
		fail("fork-clone");
	expect_state("fork-clone-state", table, 1, 2, 2);
	struct AndockMappingTable *thread = andock_mapping_table_reference(table);
	if (thread == NULL)
		fail("thread-reference");
	expect_state("thread-reference-state", table, 1, 2, 2);
	struct AndockMappingTable *exec_table = andock_mapping_table_new(&ops);
	if (exec_table == NULL || andock_mapping_table_release(thread) < 0)
		fail("exec-detach");
	expect_state("vfork-parent-state", table, 1, 2, 2);
	if (andock_mapping_table_release(exec_table) < 0
	    || andock_mapping_table_clear(table) < 0)
		fail("parent-exec-clear");
	expect_state("parent-exec-clear-state", table, 0, 1, 1);
	if (andock_mapping_table_release(table) < 0)
		fail("thread-release");
	if (andock_mapping_table_release(forked) < 0)
		fail("fork-exit");
	if (active_references != 0 || active_writable != 0
	    || retains != releases)
		fail("balanced-lifecycle");
	puts("ANDOCK_MAPPING_TEST_OK");
	return 0;
}
