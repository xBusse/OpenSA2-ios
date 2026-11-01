/* sa2_ios_nogame.c: the game's interface (sa2_ios_game.h) in an app built without the game.
 *
 * host/ios/CMakeLists.txt links this in place of libsa2game.a when SA2_IOS_GAME is empty: the build's
 * own check that the app, its screens, the installer and the renderer link and run before a game is
 * built (tools/s9/ios_app.py builds such an app when no game exists yet). A session then refuses by
 * name; the renderer check (a stream file) still plays. */
#include "sa2_ios_game.h"

#include <errno.h>
#include <stdio.h>

int sa2_ios_game_start(int argc, const char *const *argv, int end_fd, const char *end_path, size_t stack_bytes) {
    (void)argc; (void)argv; (void)end_fd; (void)end_path; (void)stack_bytes;
    fprintf(stderr, "sa2 ios: this app was built without the game (tools/s9/ios_game.py link, then ios_app.py --game)\n");
    errno = ENOSYS;
    return -1;
}

void sa2_ios_game_request_stop(void) {}

int sa2_ios_game_ended(int *code) {
    if (code) *code = 0;
    return SA2_IOS_GAME_RUNNING;
}

int sa2_ios_game_started(void) { return 0; }
