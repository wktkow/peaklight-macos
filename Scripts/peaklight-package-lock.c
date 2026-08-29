#define _DARWIN_C_SOURCE 1

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sysexits.h>
#include <time.h>
#include <unistd.h>

static void fail_errno(const char *operation, const char *path) {
    int code = errno;
    fprintf(
        stderr,
        "peaklight-package-lock: %s %s failed (errno %d: %s)\n",
        operation,
        path,
        code,
        strerror(code)
    );
    exit(EX_CANTCREAT);
}

static void fail_unsafe(const char *role, const char *path) {
    fprintf(
        stderr,
        "peaklight-package-lock: refusing unsafe %s at %s\n",
        role,
        path
    );
    exit(EX_CANTCREAT);
}

static unsigned long parse_timeout(const char *value) {
    char *end = NULL;
    errno = 0;
    unsigned long timeout = strtoul(value, &end, 10);
    if (errno != 0 || end == value || *end != '\0' || timeout > 3600UL) {
        fprintf(stderr, "peaklight-package-lock: invalid timeout %s\n", value);
        exit(EX_USAGE);
    }
    return timeout;
}

static double elapsed_seconds(
    const struct timespec *start,
    const struct timespec *end
) {
    return (double)(end->tv_sec - start->tv_sec)
        + (double)(end->tv_nsec - start->tv_nsec) / 1000000000.0;
}

int main(int argc, char *argv[]) {
    if (argc < 5) {
        fprintf(
            stderr,
            "usage: peaklight-package-lock build-directory lock-name timeout command [arguments ...]\n"
        );
        return EX_USAGE;
    }

    const char *build_directory = argv[1];
    const char *lock_name = argv[2];
    const unsigned long timeout = parse_timeout(argv[3]);
    const char *command = argv[4];

    if (build_directory[0] != '/' || command[0] != '/') {
        fprintf(stderr, "peaklight-package-lock: build directory and command must be absolute\n");
        return EX_USAGE;
    }
    if (
        lock_name[0] == '\0'
        || strcmp(lock_name, ".") == 0
        || strcmp(lock_name, "..") == 0
        || strchr(lock_name, '/') != NULL
    ) {
        fprintf(stderr, "peaklight-package-lock: lock name must be one safe path component\n");
        return EX_USAGE;
    }

    int build_descriptor = open(
        build_directory,
        O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC
    );
    if (build_descriptor < 0) {
        fail_errno("open", build_directory);
    }

    struct stat build_status;
    if (fstat(build_descriptor, &build_status) != 0) {
        fail_errno("inspect", build_directory);
    }
    if (
        (build_status.st_mode & S_IFMT) != S_IFDIR
        || build_status.st_uid != geteuid()
    ) {
        fail_unsafe("build directory", build_directory);
    }

    int lock_descriptor = openat(
        build_descriptor,
        lock_name,
        O_CREAT | O_RDWR | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC,
        S_IRUSR | S_IWUSR
    );
    if (lock_descriptor < 0) {
        fail_errno("open lock in", build_directory);
    }

    struct stat lock_status;
    if (fstat(lock_descriptor, &lock_status) != 0) {
        fail_errno("inspect lock in", build_directory);
    }
    if (
        (lock_status.st_mode & S_IFMT) != S_IFREG
        || lock_status.st_uid != geteuid()
        || lock_status.st_nlink != 1
    ) {
        fail_unsafe("lock file", lock_name);
    }
    if (fchmod(lock_descriptor, S_IRUSR | S_IWUSR) != 0) {
        fail_errno("secure lock in", build_directory);
    }

    struct timespec start;
    if (clock_gettime(CLOCK_MONOTONIC, &start) != 0) {
        fail_errno("read monotonic clock for", lock_name);
    }

    for (;;) {
        if (flock(lock_descriptor, LOCK_EX | LOCK_NB) == 0) {
            break;
        }

        int lock_errno = errno;
        if (lock_errno == EINTR) {
            continue;
        }
        if (lock_errno != EWOULDBLOCK && lock_errno != EAGAIN) {
            errno = lock_errno;
            fail_errno("lock", lock_name);
        }

        struct timespec now;
        if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) {
            fail_errno("read monotonic clock for", lock_name);
        }
        if (elapsed_seconds(&start, &now) >= (double)timeout) {
            fprintf(
                stderr,
                "peaklight-package-lock: timed out waiting for %s\n",
                lock_name
            );
            return EX_TEMPFAIL;
        }

        struct timespec pause = { .tv_sec = 0, .tv_nsec = 50000000L };
        while (nanosleep(&pause, &pause) != 0 && errno == EINTR) {
        }
    }

    if (close(build_descriptor) != 0) {
        fail_errno("close", build_directory);
    }

    if (lock_descriptor != 9) {
        if (dup2(lock_descriptor, 9) < 0) {
            fail_errno("duplicate lock descriptor for", lock_name);
        }
        if (close(lock_descriptor) != 0) {
            fail_errno("close duplicate lock descriptor for", lock_name);
        }
        lock_descriptor = 9;
    }

    int descriptor_flags = fcntl(lock_descriptor, F_GETFD);
    if (descriptor_flags < 0) {
        fail_errno("read descriptor flags for", lock_name);
    }
    if (fcntl(lock_descriptor, F_SETFD, descriptor_flags & ~FD_CLOEXEC) != 0) {
        fail_errno("preserve lock descriptor for", lock_name);
    }
    if (setenv("PEAKLIGHT_PACKAGE_LOCK_HELD", "1", 1) != 0) {
        fail_errno("set lock environment for", command);
    }

    execv(command, &argv[4]);
    fail_errno("execute", command);
}
