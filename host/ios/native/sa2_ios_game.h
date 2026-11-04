/* sa2_ios_game.h: the game as the iOS app runs it, on a thread of the app's own process.
 *
 * Every other platform runs the game as a process of its own (host/launch, host/android); iOS lets
 * an app start no other program, so the iOS build links the game into the app: tools/s9/ios_game.py
 * prelinks the lifted image, the runtime, the hooks and the driver (harness/crt_probe.c, its main
 * renamed sa2_game_main) into one object whose only global symbols are these functions, so nothing
 * of the game's can meet a symbol of the player's or SDL's. sa2_ios_game.c is in that object too.
 *
 * What a process gave the game, and what stands in for it here:
 *   - Its end. The game's own sources are compiled with exit, _exit and atexit renamed to the
 *     functions in sa2_ios_game.c (tools/s9/ios_game.py GAME_DEFINES). atexit keeps the game's
 *     handlers (the recorder's END record, the input log's totals) in a list of the game's own,
 *     which runs when sa2_game_main returns or the game calls exit, as a process's exit would
 *     run them; the game's thread then ends, or parks if it was a guest thread that called exit,
 *     and the end is written to `end_fd` (one byte) for the session to see. _exit, which the
 *     runtime calls only where it cannot go on (a fault outside any call, a stuck call), ends the
 *     whole app as it ended the game's process, after saying so on stderr and in the end file;
 *     the next launch finds the session marked as running and shows its log.
 *   - SIGTERM, the launcher's stop: sa2_ios_game_request_stop (runtime/sa2_dinput.c
 *     sa2_dinput_request_stop), so the next keyboard poll posts WM_QUIT.
 *   - Its environment, working folder and standard streams: the session sets the game's SA2_
 *     settings in the app's environment, makes the session folder the working folder and sends
 *     stdout and stderr to the session's console log before it starts the game
 *     (host/ios/native/sa2_ios_session.mm).
 * The runtime keeps its state in globals, so a game runs once in an app's life: a second start is
 * refused, and the app is quit and opened again to play again.
 */
#ifndef SA2_IOS_GAME_H
#define SA2_IOS_GAME_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* How the game ended (sa2_ios_game_ended). */
enum {
    SA2_IOS_GAME_RUNNING = 0,
    SA2_IOS_GAME_RETURNED = 1,   /* sa2_game_main returned */
    SA2_IOS_GAME_EXITED = 2,     /* the game called exit() */
};

/* Starts sa2_game_main(argc, argv) on a new thread with a stack of `stack_bytes` (0: 64 MiB, a guest
 * thread's, runtime/sa2_threads.c), copying the arguments. When the game ends, one byte is written to
 * `end_fd` (-1: none), and `end_path` (NULL: none) gets a line saying how. 0 when started; -1 with
 * errno when the thread could not start; -2 when a game has run already in this process. */
int sa2_ios_game_start(int argc, const char *const *argv, int end_fd, const char *end_path, size_t stack_bytes);

/* The stop a SIGTERM asked of the game's process: the next keyboard poll posts WM_QUIT. */
void sa2_ios_game_request_stop(void);

/* SA2_IOS_GAME_RUNNING while the game runs (or before it starts), else how it ended, with its code. */
int sa2_ios_game_ended(int *code);

/* Whether a game has been started in this process (it cannot be started again). */
int sa2_ios_game_started(void);

#ifdef __cplusplus
}
#endif

#endif
