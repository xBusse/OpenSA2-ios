// sa2_ios_session.h: the iOS app's native side, as its Swift screens call it (host/ios/app, through
// the bridging header). Plain C, so Swift sees every function and struct as they are.
//
// The folders (sa2ios_init):
//   files      Library/Application Support/SA2: HOME, $XDG_CONFIG_HOME (files/config: the
//              installer's config, host/install/sa2_config.h) and $XDG_DATA_HOME (files/data: its
//              manifest and the overlay the game writes its saves and config into). Not shown in
//              the Files app, and kept by an update.
//   documents  Documents, which the Files app shows: Game/ (the game folder a user copies in),
//              Sessions/ (one folder per session: its report, console log and records),
//              game.env.extra (SA2_ lines a measurement adds, as on Android) and last-session.txt.
//   caches     Library/Caches/SA2: the session's FIFOs and pipes' files (never shown, as the Files
//              app should never open a FIFO).
//   bundle     the app's resources: game.env (the game's settings, tools/s9/ios_app.py).
#pragma once

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

void sa2ios_init(const char* files, const char* documents, const char* caches, const char* bundle);

// ---------------------------------------------------------------- the installation

// The installation, as the session would find it: 1 ready, 0 none (never installed), -1 one that
// must be made again (another hash table, or its folder is gone); `why` says which. `game` gets
// the game folder and `overlay` the folder the game writes into (either may be NULL).
int sa2ios_install_status(char* game, size_t game_n, char* overlay, size_t overlay_n, char* why, size_t why_n);

// The installer (host/install, sa2-install) on this thread: `kind` "folder" or "zip", `path` the
// game folder or the ZIP of one; everything it prints goes to `log_path` (truncated). Its exit code:
// 0 accepted, 2 usage, 3 refused, 4 not found, 5 I/O error, 6 ambiguous (sa2_install_cli.cpp).
int sa2ios_install(const char* kind, const char* path, const char* log_path);

// The folder under `root` that holds a game: `root` itself, or its one subfolder that does (a
// "Sonic Adventure 2" folder copied in whole). 1 with `out` set, 0 when none does.
int sa2ios_find_game_folder(const char* root, char* out, size_t n);

// ---------------------------------------------------------------- a session

typedef struct {
    int screen_w, screen_h;          // the screen in pixels, in the session's orientation
    const char* orientation;         // "landscape" (default), "portrait" or "auto"
    int audio;                       // 0: --no-audio
    int pace;                        // 0: --no-pace
    const char* const* settings;     // "SA2_K=V" each: the settings screen's, before game.env.extra
    int setting_count;
    const char* stream;              // a recorded stream file: the renderer check, no game
    const char* max_frames;          // with `stream`: stop after this many frames ("" or NULL: all)
    int menu_button;                 // the in-game menu's button (0: the three-finger tap alone)
    int debug_hud;                   // the in-game log and relay counters, from the start
} sa2ios_play_args;

// Runs a session on this thread, which must be the app's main thread (the player is SDL's): the
// game on a thread of its own and the player here, until the player ends. Its exit code (0 OK). The
// session's folder is written to `session` (may be NULL). A game runs once in an app's life
// (sa2_ios_game.h): a second call refuses, and the app is opened again to play again.
int sa2ios_play(const sa2ios_play_args* args, char* session, size_t session_n);

// Whether a session has run in this process (the app must be opened again for another).
int sa2ios_session_has_run(void);
// The report of the last session (Documents/last-session.txt).
void sa2ios_report_path(char* out, size_t n);
// Asks the running session to end, as the player's window close would (the in-game menu's End).
void sa2ios_request_end(void);

// The newest session folder that is marked as still running (the app ended inside it: a crash, or
// iOS ending the app), "" when none; its marker is removed so it is reported once.
void sa2ios_crashed_session(char* out, size_t n);

// The saves the game sees (the overlay's resource/gd_PC/SAVEDATA over the game folder's), copied to
// `dest` (created). The number of files, -1 on failure (`why` set).
int sa2ios_export_saves(const char* dest, char* why, size_t why_n);
// Every file in `src` copied into the overlay's save folder, replacing one of the same name (case
// blind, as the game matches). The number of files, -1 on failure (`why` set).
int sa2ios_import_saves(const char* src, char* why, size_t why_n);

#ifdef __cplusplus
}
#endif
