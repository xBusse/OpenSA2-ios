/* sa2_ios_game.c: the game's thread and its end, in the iOS app (sa2_ios_game.h says why).
 *
 * Compiled into the game's prelinked object (tools/s9/ios_game.py) *without* the exit, _exit and
 * atexit renames the game's own sources get, so the real ones are reachable here. */
#include "sa2_ios_game.h"
#include "sa2_ios_console.h"   /* sa2ios_console_drain: the app's, resolved when the app links the game */

#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* harness/crt_probe.c's main, renamed (tools/s9/ios_game.py). */
extern int sa2_game_main(int argc, char **argv);
/* runtime/sa2_dinput.c. */
extern void sa2_dinput_request_stop(void);

#define MAX_ATEXIT 64

static pthread_mutex_t g_mu = PTHREAD_MUTEX_INITIALIZER;
static void (*g_atexit[MAX_ATEXIT])(void);
static int g_atexit_n;
static atomic_int g_atexit_ran;

static atomic_int g_started;
static atomic_int g_state;          /* SA2_IOS_GAME_* */
static atomic_int g_code;
static int g_end_fd = -1;
static char g_end_path[1024];

static int g_argc;
static char **g_argv;
static pthread_t g_thread;

/* ------------------------------------------------------------------ the renamed CRT ends */

/* The game's atexit: its own list, run by run_atexits as a process's exit runs them, last first. */
int sa2_ios_game_atexit(void (*fn)(void)) {
    if (!fn) return -1;
    pthread_mutex_lock(&g_mu);
    const int ok = g_atexit_n < MAX_ATEXIT;
    if (ok) g_atexit[g_atexit_n++] = fn;
    pthread_mutex_unlock(&g_mu);
    if (!ok) fprintf(stderr, "sa2 ios: the game's atexit list is full (%d); a handler is not kept\n", MAX_ATEXIT);
    return ok ? 0 : -1;
}

static void run_atexits(void) {
    if (atomic_exchange(&g_atexit_ran, 1)) return;
    for (;;) {
        void (*fn)(void) = NULL;
        pthread_mutex_lock(&g_mu);
        if (g_atexit_n > 0) fn = g_atexit[--g_atexit_n];
        pthread_mutex_unlock(&g_mu);
        if (!fn) break;
        fn();
    }
    fflush(NULL);
}

/* The end, said where the session looks: a line in the end file and a byte on the end pipe. Only
 * write(2) and open(2), so a caller in a signal handler (_exit's) is served too. */
static void announce(int state, int code, const char *how) {
    atomic_store(&g_code, code);
    atomic_store(&g_state, state);
    if (g_end_path[0]) {
        const int fd = open(g_end_path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
        if (fd >= 0) {
            char line[160];
            int n = snprintf(line, sizeof line, "%s %d\n", how, code);
            if (n > 0) {
                ssize_t ignored = write(fd, line, (size_t)n);
                (void)ignored;
            }
            close(fd);
        }
    }
    if (g_end_fd >= 0) {
        const char byte = (char)state;
        ssize_t ignored = write(g_end_fd, &byte, 1);
        (void)ignored;
    }
}

/* The game's exit: its handlers, then the end; the game's thread ends here, a guest thread parks. */
__attribute__((noreturn)) void sa2_ios_game_exit(int code) {
    fflush(NULL);
    run_atexits();
    fprintf(stderr, "sa2 ios: the game called exit(%d)\n", code);
    fflush(stderr);
    announce(SA2_IOS_GAME_EXITED, code, "exit");
    if (pthread_equal(pthread_self(), g_thread)) pthread_exit(NULL);
    for (;;) pause();
}

/* The game's _exit: where the runtime cannot go on, the app ends as the game's process did. */
__attribute__((noreturn)) void sa2_ios_game__exit(int code) {
    static const char said[] = "sa2 ios: the game called _exit: the app ends with it (the next launch shows this "
                               "session's log)\n";
    ssize_t ignored = write(2, said, sizeof said - 1);
    (void)ignored;
    announce(SA2_IOS_GAME_EXITED, code, "_exit");
    /* The console's reader (the app's, sa2_ios_console.mm) writes the last lines, this one and
     * whatever the runtime said before it, to the session's console.log before the app ends. */
    sa2ios_console_drain();
    _exit(code);
}

/* ------------------------------------------------------------------ the game's thread */

static void *game_body(void *arg) {
    (void)arg;
    pthread_setname_np("sa2-game");
    const int code = sa2_game_main(g_argc, g_argv);
    fflush(NULL);
    run_atexits();
    fprintf(stderr, "sa2 ios: the game returned %d\n", code);
    fflush(stderr);
    announce(SA2_IOS_GAME_RETURNED, code, "returned");
    return NULL;
}

int sa2_ios_game_start(int argc, const char *const *argv, int end_fd, const char *end_path, size_t stack_bytes) {
    if (atomic_exchange(&g_started, 1)) return -2;
    g_argv = calloc((size_t)argc + 1, sizeof *g_argv);
    if (!g_argv) {
        errno = ENOMEM;
        return -1;
    }
    for (int i = 0; i < argc; i++) g_argv[i] = strdup(argv[i]);
    g_argc = argc;
    g_end_fd = end_fd;
    snprintf(g_end_path, sizeof g_end_path, "%s", end_path ? end_path : "");
    pthread_attr_t at;
    pthread_attr_init(&at);
    pthread_attr_setstacksize(&at, stack_bytes ? stack_bytes : ((size_t)64 << 20));
    /* The game's guest threads run one at a time, and its frame is the app's: the highest QoS a
     * thread can ask for, so the scheduler keeps it on a performance core. */
    pthread_attr_set_qos_class_np(&at, QOS_CLASS_USER_INTERACTIVE, 0);
    const int rc = pthread_create(&g_thread, &at, game_body, NULL);
    pthread_attr_destroy(&at);
    if (rc) {
        errno = rc;
        return -1;
    }
    pthread_detach(g_thread);
    return 0;
}

void sa2_ios_game_request_stop(void) { sa2_dinput_request_stop(); }

int sa2_ios_game_ended(int *code) {
    const int s = atomic_load(&g_state);
    if (code) *code = atomic_load(&g_code);
    return s;
}

int sa2_ios_game_started(void) { return atomic_load(&g_started); }
