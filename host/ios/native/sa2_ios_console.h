// sa2_ios_console.h: the app's standard output and error, kept.
//
// The game, the player, SDL and the installer all say what they do on stdout and stderr, and on iOS
// those go nowhere a user can read. sa2ios_console_start points both descriptors at a pipe whose
// reader thread writes every line to the current log file (the app's own, an installation's, or a
// session's console.log) and to the unified log (os_log, subsystem "com.sa2recomp.ios", category
// "console"), where Xcode's console and Console.app show them while a phone is attached.
#pragma once

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// Starts the capture, writing to `path` (appended). Once; a second call only switches the file.
void sa2ios_console_start(const char* path);
// Writes from now on to `path` (truncated first when `truncate`); NULL goes back to the app's log.
// Every line written before the call is in the old file when it returns.
void sa2ios_console_switch(const char* path, int truncate);
// The file written now ("" before the start).
void sa2ios_console_path(char* out, size_t n);
// One line from the app itself (the session's report lines, the UI's notes), through the capture.
void sa2ios_console_line(const char* line);
// Waits (at most about a second) until every byte written to stdout and stderr so far is in the
// file: a marker through the pipe, as a switch writes. Only write(2), atomics and nanosleep, so the
// game's _exit (sa2_ios_game.c), which a signal handler may call, can wait for its last lines before
// it ends the app; it also runs at the app's exit (atexit). Without the capture, it returns at once.
void sa2ios_console_drain(void);

#ifdef __cplusplus
}
#endif
