// sa2_ios_ingame.h: what the iOS app lays over the game's window while a session plays.
//
// The player owns the window (SDL's UIWindow and its view); this adds two UIKit views to SDL's own
// view once the window exists, and takes them away when the session ends:
//   - the menu: a small translucent button at the top of the screen, below the touch overlay's
//     START (or, with the button turned off, a tap with three fingers anywhere), opening Resume,
//     the debug overlay on or off, Copy session folder, and End session (which asks the player to
//     end, as closing its window would: sa2ios_request_end);
//   - the debug overlay: the last lines of the session's console log and one line of the session's
//     counters (frames the relay handed on, the game's state), refreshed twice a second, which takes
//     no touches, so the touch controls under it still work.
// Neither pauses the game: the game's own pause is START.
#pragma once

#include <functional>
#include <string>

struct Sa2IosIngame {
    std::string console_path;               // the session's console.log
    std::string session;                    // the session's folder (Copy session folder)
    std::function<std::string()> status;    // the counters' line, called on the main thread
    bool menu_button = true;
    bool hud = false;
};

// Called on the main thread before the player starts: the views are added once SDL's window exists.
void sa2ios_ingame_begin(const Sa2IosIngame& info);
// Called on the main thread after the player has returned.
void sa2ios_ingame_end();
