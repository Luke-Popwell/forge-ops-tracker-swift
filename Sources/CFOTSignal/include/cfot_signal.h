#ifndef CFOT_SIGNAL_H
#define CFOT_SIGNAL_H

/**
 * Installs handlers for the common fatal signals (SIGABRT, SIGILL, SIGSEGV, SIGFPE, SIGBUS,
 * SIGTRAP) that write a raw backtrace to disk -- the exact same approach as this repo's own
 * Objective-C client (sdks/objc/Sources/ForgeOpsTracker/FOTSignalHandler.m), and written in plain
 * C for the same reason it's plain C there too: inside an actual signal handler, only
 * async-signal-safe functions are safe to call at all (POSIX is explicit about this) -- no
 * malloc, no ARC retain/release, none of what Swift's runtime does implicitly on nearly every
 * line of ordinary Swift code (reference counting, potential allocation for String/Array,
 * dynamic dispatch). Rather than trying to hand-write Swift careful enough to trust in a real
 * crash, this is one small, already-proven C implementation, shared with (not reimplemented
 * per-language from) the Objective-C client.
 *
 * crash_reports_directory must already exist and outlive the handler installation -- the caller
 * (SignalHandler.swift) creates it via ordinary safe Foundation code before calling this.
 *
 * This path isn't exercised by this SDK's own automated test suite -- deliberately: actually
 * raising a fatal signal to test it would crash the test process itself, the same reason every
 * real crash reporter's signal path is validated by manual/integration crash testing, not a unit
 * test. Installation succeeding is tested; the handler's own body is not.
 */
void cfot_install_signal_handlers(const char *crash_reports_directory);

#endif
