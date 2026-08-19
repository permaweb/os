#define _GNU_SOURCE

#include <errno.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static long parse_positive(const char *value)
{
	char *end = NULL;
	long result;

	errno = 0;
	result = strtol(value, &end, 10);
	if (errno != 0 || end == value || *end != '\0' || result <= 0) {
		fprintf(stderr, "invalid positive integer: %s\n", value);
		exit(2);
	}
	return result;
}

static int probe_memory(long mib)
{
	const size_t chunk_size = 1024U * 1024U;
	void **chunks = calloc((size_t)mib, sizeof(*chunks));
	long allocated;

	if (chunks == NULL)
		return 3;
	for (allocated = 0; allocated < mib; allocated++) {
		chunks[allocated] = malloc(chunk_size);
		if (chunks[allocated] == NULL) {
			printf("allocated-mib=%ld\n", allocated);
			return 4;
		}
		memset(chunks[allocated], 0xa5, chunk_size);
	}
	printf("allocated-mib=%ld\n", allocated);
	sleep(2);
	return 0;
}

static int probe_pids(long requested)
{
	pid_t *children = calloc((size_t)requested, sizeof(*children));
	long started;

	if (children == NULL)
		return 3;
	for (started = 0; started < requested; started++) {
		pid_t child = fork();
		if (child < 0)
			break;
		if (child == 0) {
			for (;;)
				pause();
		}
		children[started] = child;
	}
	printf("started-pids=%ld requested-pids=%ld errno=%d\n",
	       started, requested, errno);
	fflush(stdout);
	while (started > 0) {
		started--;
		kill(children[started], SIGKILL);
		waitpid(children[started], NULL, 0);
	}
	return 0;
}

static double elapsed(const struct timespec *start, const struct timespec *end)
{
	return (double)(end->tv_sec - start->tv_sec) +
	       (double)(end->tv_nsec - start->tv_nsec) / 1000000000.0;
}

static int probe_cpu(long seconds)
{
	struct timespec wall_start, wall_now, cpu_start, cpu_now;
	volatile uint64_t accumulator = 0;

	clock_gettime(CLOCK_MONOTONIC, &wall_start);
	clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &cpu_start);
	do {
		for (unsigned int index = 0; index < 1000000U; index++)
			accumulator = accumulator * 33U + index;
		clock_gettime(CLOCK_MONOTONIC, &wall_now);
	} while (elapsed(&wall_start, &wall_now) < (double)seconds);
	clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &cpu_now);
	printf("wall-seconds=%.3f cpu-seconds=%.3f accumulator=%llu\n",
	       elapsed(&wall_start, &wall_now), elapsed(&cpu_start, &cpu_now),
	       (unsigned long long)accumulator);
	return 0;
}

int main(int argc, char **argv)
{
	long amount;

	if (argc != 3) {
		fprintf(stderr, "usage: resource-probe memory MIB | pids COUNT | cpu SECONDS\n");
		return 2;
	}
	amount = parse_positive(argv[2]);
	if (strcmp(argv[1], "memory") == 0)
		return probe_memory(amount);
	if (strcmp(argv[1], "pids") == 0)
		return probe_pids(amount);
	if (strcmp(argv[1], "cpu") == 0)
		return probe_cpu(amount);
	fprintf(stderr, "unknown probe: %s\n", argv[1]);
	return 2;
}
