#include "include/cfot_signal.h"
#include <execinfo.h>
#include <fcntl.h>
#include <limits.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static const int kFatalSignals[] = { SIGABRT, SIGILL, SIGSEGV, SIGFPE, SIGBUS, SIGTRAP };
static const size_t kFatalSignalCount = sizeof(kFatalSignals) / sizeof(kFatalSignals[0]);

/* Prepared once, at installation time, so the handler itself never allocates -- see this file's
 * own header comment for why that matters here. */
static char crash_directory[PATH_MAX];

static void handle_fatal_signal(int signal_number) {
    char path[PATH_MAX];
    /* snprintf and time() aren't on POSIX's strict async-signal-safe list, but both are widely
     * relied on in practice by real-world signal handlers -- this repo's own Objective-C client
     * takes the same pragmatic stance rather than hand-rolling an integer-to-string formatter
     * (see FOTSignalHandler.m's own comment); documented here as a deliberate, informed
     * tradeoff, not an oversight. */
    snprintf(path, sizeof(path), "%s/signal-%d-%ld.txt", crash_directory, signal_number, (long)time(NULL));

    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd >= 0) {
        const char *name = strsignal(signal_number);
        if (name != NULL) {
            write(fd, name, strlen(name));
            write(fd, "\n", 1);
        }

        void *frames[64];
        int frame_count = backtrace(frames, 64);
        /* backtrace_symbols_fd(), unlike backtrace_symbols(), writes directly to a file
         * descriptor without allocating a string array first -- documented by both glibc and
         * Darwin's own libc as the signal-safer of the two for exactly this reason. */
        backtrace_symbols_fd(frames, frame_count, fd);

        close(fd);
    }

    /* Restore the default disposition and re-raise, rather than swallowing the signal -- the
     * process should still actually crash (and produce a real OS-level crash log) the same way
     * it would without this handler installed, the same "rethrow, don't swallow" invariant every
     * other framework integration in this repo holds to. */
    signal(signal_number, SIG_DFL);
    raise(signal_number);
}

void cfot_install_signal_handlers(const char *crash_reports_directory) {
    strlcpy(crash_directory, crash_reports_directory, sizeof(crash_directory));

    struct sigaction action;
    memset(&action, 0, sizeof(action));
    action.sa_handler = handle_fatal_signal;
    sigemptyset(&action.sa_mask);
    action.sa_flags = 0;

    for (size_t i = 0; i < kFatalSignalCount; i++) {
        sigaction(kFatalSignals[i], &action, NULL);
    }
}
