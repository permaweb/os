#include <errno.h>
#include <limits.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>

#include "extension/andock_image/andock_mapping.h"

struct AndockMapping {
	uintptr_t start;
	uintptr_t end;
	uint64_t cache_id;
	bool writable;
	struct AndockMapping *next;
};

struct AndockMappingTable {
	/* One table models one Linux mm.  Each range owns one engine reference. */
	unsigned int references;
	struct AndockMappingOps ops;
	struct AndockMapping *mappings;
};

static bool mapping_end(uintptr_t start, size_t length, uintptr_t *end)
{
	if (length == 0 || length > UINTPTR_MAX - start)
		return false;
	*end = start + length;
	return true;
}

static int release_mapping(struct AndockMappingTable *table,
		struct AndockMapping *mapping)
{
	int status = table->ops.release(mapping->cache_id, mapping->writable);
	free(mapping);
	return status;
}

static int retain_mapping(struct AndockMappingTable *table,
		struct AndockMapping *mapping)
{
	return table->ops.retain(mapping->cache_id, mapping->writable);
}

static int merge_mappings(struct AndockMappingTable *table)
{
	int first_error = 0;
	struct AndockMapping *mapping = table->mappings;
	while (mapping != NULL && mapping->next != NULL) {
		struct AndockMapping *next = mapping->next;
		if (mapping->end != next->start
		    || mapping->cache_id != next->cache_id
		    || mapping->writable != next->writable) {
			mapping = next;
			continue;
		}
		mapping->end = next->end;
		mapping->next = next->next;
		int status = release_mapping(table, next);
		if (status < 0 && first_error == 0)
			first_error = status;
	}
	return first_error;
}

static int insert_mapping(struct AndockMappingTable *table,
		uintptr_t start, uintptr_t end, uint64_t cache_id, bool writable)
{
	struct AndockMapping *mapping = calloc(1, sizeof(*mapping));
	if (mapping == NULL)
		return -ENOMEM;
	mapping->start = start;
	mapping->end = end;
	mapping->cache_id = cache_id;
	mapping->writable = writable;
	int status = retain_mapping(table, mapping);
	if (status < 0) {
		free(mapping);
		return status;
	}
	struct AndockMapping **cursor = &table->mappings;
	while (*cursor != NULL && (*cursor)->start < start)
		cursor = &(*cursor)->next;
	mapping->next = *cursor;
	*cursor = mapping;
	return merge_mappings(table);
}

static int remove_range(struct AndockMappingTable *table,
		uintptr_t start, uintptr_t end)
{
	int first_error = 0;
	struct AndockMapping **cursor = &table->mappings;
	while (*cursor != NULL) {
		struct AndockMapping *mapping = *cursor;
		if (mapping->end <= start) {
			cursor = &mapping->next;
			continue;
		}
		if (mapping->start >= end)
			break;
		if (start <= mapping->start && end >= mapping->end) {
			*cursor = mapping->next;
			int status = release_mapping(table, mapping);
			if (status < 0 && first_error == 0)
				first_error = status;
			continue;
		}
		if (start <= mapping->start) {
			mapping->start = end;
			break;
		}
		if (end >= mapping->end) {
			mapping->end = start;
			cursor = &mapping->next;
			continue;
		}
		struct AndockMapping *right = malloc(sizeof(*right));
		if (right == NULL) {
			if (first_error == 0)
				first_error = -ENOMEM;
			break;
		}
		*right = *mapping;
		right->start = end;
		int status = retain_mapping(table, right);
		if (status < 0) {
			free(right);
			if (first_error == 0)
				first_error = status;
			break;
		}
		mapping->end = start;
		mapping->next = right;
		break;
	}
	return first_error;
}

struct AndockMappingTable *andock_mapping_table_new(
		const struct AndockMappingOps *ops)
{
	if (ops == NULL || ops->retain == NULL || ops->release == NULL)
		return NULL;
	struct AndockMappingTable *table = calloc(1, sizeof(*table));
	if (table != NULL) {
		table->references = 1;
		table->ops = *ops;
	}
	return table;
}

struct AndockMappingTable *andock_mapping_table_reference(
		struct AndockMappingTable *table)
{
	if (table == NULL || table->references == UINT_MAX)
		return NULL;
	table->references++;
	return table;
}

struct AndockMappingTable *andock_mapping_table_clone(
		const struct AndockMappingTable *source)
{
	if (source == NULL)
		return NULL;
	struct AndockMappingTable *table = andock_mapping_table_new(&source->ops);
	if (table == NULL)
		return NULL;
	const struct AndockMapping *mapping = source->mappings;
	while (mapping != NULL) {
		int status = insert_mapping(table, mapping->start, mapping->end,
			mapping->cache_id, mapping->writable);
		if (status < 0) {
			andock_mapping_table_release(table);
			return NULL;
		}
		mapping = mapping->next;
	}
	return table;
}

int andock_mapping_table_clear(struct AndockMappingTable *table)
{
	if (table == NULL)
		return -EINVAL;
	int first_error = 0;
	while (table->mappings != NULL) {
		struct AndockMapping *mapping = table->mappings;
		table->mappings = mapping->next;
		int status = release_mapping(table, mapping);
		if (status < 0 && first_error == 0)
			first_error = status;
	}
	return first_error;
}

int andock_mapping_table_release(struct AndockMappingTable *table)
{
	if (table == NULL || table->references == 0)
		return -EINVAL;
	if (--table->references != 0)
		return 0;
	int status = andock_mapping_table_clear(table);
	free(table);
	return status;
}

int andock_mapping_replace(struct AndockMappingTable *table,
		uintptr_t start, size_t length, uint64_t cache_id, bool writable)
{
	uintptr_t end;
	if (table == NULL || !mapping_end(start, length, &end))
		return -EINVAL;
	int first_error = remove_range(table, start, end);
	if (cache_id != 0) {
		int status = insert_mapping(table, start, end, cache_id, writable);
		if (status < 0 && first_error == 0)
			first_error = status;
	}
	return first_error;
}

int andock_mapping_unmap(struct AndockMappingTable *table,
		uintptr_t start, size_t length)
{
	uintptr_t end;
	if (table == NULL || !mapping_end(start, length, &end))
		return -EINVAL;
	return remove_range(table, start, end);
}

static int change_writable(struct AndockMappingTable *table,
		struct AndockMapping *mapping, bool writable)
{
	if (mapping->writable == writable)
		return 0;
	int status = table->ops.retain(mapping->cache_id, writable);
	if (status < 0)
		return status;
	status = table->ops.release(mapping->cache_id, mapping->writable);
	mapping->writable = writable;
	return status;
}

int andock_mapping_protect(struct AndockMappingTable *table,
		uintptr_t start, size_t length, bool writable)
{
	uintptr_t end;
	if (table == NULL || !mapping_end(start, length, &end))
		return -EINVAL;
	struct AndockMapping *mapping = table->mappings;
	while (mapping != NULL) {
		if (mapping->end <= start) {
			mapping = mapping->next;
			continue;
		}
		if (mapping->start >= end)
			break;
		if (mapping->start < start) {
			struct AndockMapping *right = malloc(sizeof(*right));
			if (right == NULL) {
				/* Over-track writes rather than lose persistence under OOM. */
				int status = writable
					? change_writable(table, mapping, true) : 0;
				if (status < 0)
					return status;
				mapping = mapping->next;
				continue;
			}
			*right = *mapping;
			right->start = start;
			int status = retain_mapping(table, right);
			if (status < 0) {
				free(right);
				status = writable
					? change_writable(table, mapping, true) : 0;
				if (status < 0)
					return status;
				mapping = mapping->next;
				continue;
			}
			mapping->end = start;
			mapping->next = right;
			mapping = right;
		}
		if (mapping->end > end) {
			struct AndockMapping *right = malloc(sizeof(*right));
			if (right == NULL) {
				int status = writable
					? change_writable(table, mapping, true) : 0;
				if (status < 0)
					return status;
				mapping = mapping->next;
				continue;
			}
			*right = *mapping;
			right->start = end;
			int status = retain_mapping(table, right);
			if (status < 0) {
				free(right);
				status = writable
					? change_writable(table, mapping, true) : 0;
				if (status < 0)
					return status;
				mapping = mapping->next;
				continue;
			}
			mapping->end = end;
			mapping->next = right;
		}
		int status = change_writable(table, mapping, writable);
		if (status < 0)
			return status;
		mapping = mapping->next;
	}
	return merge_mappings(table);
}

struct RemappedRange {
	uintptr_t offset;
	size_t length;
	uint64_t cache_id;
	bool writable;
	struct RemappedRange *next;
};

static int free_remapped_ranges(struct AndockMappingTable *table,
		struct RemappedRange *ranges)
{
	int first_error = 0;
	while (ranges != NULL) {
		struct RemappedRange *range = ranges;
		ranges = range->next;
		int status = range->cache_id == 0 ? 0 : table->ops.release(
			range->cache_id, range->writable);
		if (status < 0 && first_error == 0)
			first_error = status;
		free(range);
	}
	return first_error;
}

int andock_mapping_remap(struct AndockMappingTable *table,
		uintptr_t old_start, size_t old_length, uintptr_t new_start,
		size_t new_length, bool keep_old)
{
	uintptr_t old_end;
	uintptr_t new_end;
	if (table == NULL || !mapping_end(old_start, old_length, &old_end)
	    || !mapping_end(new_start, new_length, &new_end))
		return -EINVAL;
	struct RemappedRange *ranges = NULL;
	struct RemappedRange **tail = &ranges;
	const struct AndockMapping *mapping = table->mappings;
	while (mapping != NULL && mapping->start < old_end) {
		if (mapping->end > old_start) {
			uintptr_t start = mapping->start > old_start
				? mapping->start : old_start;
			uintptr_t end = mapping->end < old_end
				? mapping->end : old_end;
			if ((size_t)(start - old_start) < new_length) {
				struct RemappedRange *range = calloc(1, sizeof(*range));
				if (range == NULL) {
					free_remapped_ranges(table, ranges);
					return -ENOMEM;
				}
				range->offset = start - old_start;
				range->length = end - start;
				if (range->length > new_length - range->offset)
					range->length = new_length - range->offset;
				range->cache_id = mapping->cache_id;
				range->writable = mapping->writable;
				int status = table->ops.retain(
					range->cache_id, range->writable);
				if (status < 0) {
					free(range);
					free_remapped_ranges(table, ranges);
					return status;
				}
				*tail = range;
				tail = &range->next;
			}
		}
		mapping = mapping->next;
	}
	if (new_length > old_length) {
		const struct AndockMapping *last = table->mappings;
		while (last != NULL && last->end <= old_start)
			last = last->next;
		while (last != NULL && last->end < old_end)
			last = last->next;
		if (last != NULL && last->start < old_end && last->end >= old_end) {
			struct RemappedRange *range = calloc(1, sizeof(*range));
			if (range == NULL) {
				free_remapped_ranges(table, ranges);
				return -ENOMEM;
			}
			range->offset = old_length;
			range->length = new_length - old_length;
			range->cache_id = last->cache_id;
			range->writable = last->writable;
			int status = table->ops.retain(
				range->cache_id, range->writable);
			if (status < 0) {
				free(range);
				free_remapped_ranges(table, ranges);
				return status;
			}
			*tail = range;
		}
	}
	int first_error = 0;
	if (!keep_old) {
		int status = remove_range(table, old_start, old_end);
		if (status < 0)
			first_error = status;
	}
	if (new_start != old_start || keep_old) {
		int status = remove_range(table, new_start, new_end);
		if (status < 0 && first_error == 0)
			first_error = status;
	}
	struct RemappedRange *range = ranges;
	while (range != NULL) {
		int status = insert_mapping(table, new_start + range->offset,
			new_start + range->offset + range->length,
			range->cache_id, range->writable);
		if (status < 0) {
			if (first_error == 0)
				first_error = status;
			/* Keep the temporary engine hold as a conservative OOM fallback. */
			range->cache_id = 0;
		}
		range = range->next;
	}
	int release_status = free_remapped_ranges(table, ranges);
	if (release_status < 0 && first_error == 0)
		first_error = release_status;
	return first_error < 0 ? first_error : merge_mappings(table);
}

size_t andock_mapping_count(const struct AndockMappingTable *table)
{
	size_t count = 0;
	const struct AndockMapping *mapping = table == NULL
		? NULL : table->mappings;
	while (mapping != NULL) {
		count++;
		mapping = mapping->next;
	}
	return count;
}
