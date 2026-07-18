#ifndef ANDOCK_MAPPING_H
#define ANDOCK_MAPPING_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

struct AndockMappingOps {
	int (*retain)(uint64_t cache_id, bool writable);
	int (*release)(uint64_t cache_id, bool writable);
};

struct AndockMappingTable;

struct AndockMappingTable *andock_mapping_table_new(
	const struct AndockMappingOps *ops);
struct AndockMappingTable *andock_mapping_table_reference(
	struct AndockMappingTable *table);
struct AndockMappingTable *andock_mapping_table_clone(
	const struct AndockMappingTable *table);
int andock_mapping_table_clear(struct AndockMappingTable *table);
int andock_mapping_table_release(struct AndockMappingTable *table);
int andock_mapping_replace(struct AndockMappingTable *table,
	uintptr_t start, size_t length, uint64_t cache_id, bool writable);
int andock_mapping_unmap(struct AndockMappingTable *table,
	uintptr_t start, size_t length);
int andock_mapping_protect(struct AndockMappingTable *table,
	uintptr_t start, size_t length, bool writable);
int andock_mapping_remap(struct AndockMappingTable *table,
	uintptr_t old_start, size_t old_length, uintptr_t new_start,
	size_t new_length, bool keep_old);
size_t andock_mapping_count(const struct AndockMappingTable *table);

#endif
