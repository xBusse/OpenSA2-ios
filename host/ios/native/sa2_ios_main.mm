// sa2_ios_main.mm: the iOS app's main, as SDL runs it.
//
// SDL owns the app on iOS: <SDL3/SDL_main.h> turns this main into SDL_main, and SDL's own main
// starts UIKit with SDL's app and scene delegates (Info.plist: UIApplicationSceneManifest names
// SDLUIKitSceneDelegate), which call it once the scene is connected, on the main thread, inside the
// main run loop. Everything else happens from here:
//   1. the folders and the console (sa2ios_init, sa2ios_console_start);
//   2. the launcher: the app's own screens (host/ios/app, SwiftUI, in a UIWindow of SDL's scene),
//      which spin the main run loop until the user starts a session (sa2ios_launcher_run);
//   3. the session (sa2ios_play), whose player makes SDL's window over the launcher's;
//   4. the launcher again, with the session's report, until the user quits (a game runs once in
//      an app's life: sa2_ios_game.h).
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#include <SDL3/SDL.h>
#include <SDL3/SDL_main.h>

#include "sa2_ios_console.h"
#include "sa2_ios_session.h"

#include <cstdio>
#include <string>

// host/ios/app/Launcher.swift, exported with @_cdecl.
extern "C" int sa2ios_launcher_run(sa2ios_play_args* out);
extern "C" void sa2ios_launcher_after_session(int code, const char* session);

static std::string dir_of(NSSearchPathDirectory which, NSString* sub) {
    NSArray<NSString*>* paths = NSSearchPathForDirectoriesInDomains(which, NSUserDomainMask, YES);
    NSString* p = paths.firstObject ?: NSTemporaryDirectory();
    if (sub) p = [p stringByAppendingPathComponent:sub];
    [[NSFileManager defaultManager] createDirectoryAtPath:p withIntermediateDirectories:YES attributes:nil error:nil];
    return p.UTF8String;
}

int main(int argc, char* argv[]) {
    (void)argc;
    (void)argv;
    @autoreleasepool {
        const std::string files = dir_of(NSApplicationSupportDirectory, @"SA2");
        const std::string docs = dir_of(NSDocumentDirectory, nil);
        const std::string caches = dir_of(NSCachesDirectory, @"SA2");
        const std::string bundle = [[NSBundle mainBundle] resourcePath].UTF8String;
        // The app's own log: the last launch's kept beside it.
        const std::string log = docs + "/app.log";
        std::rename(log.c_str(), (docs + "/app.previous.log").c_str());
        sa2ios_console_start(log.c_str());
        std::fprintf(stderr, "sa2recomp (iOS) %s; SDL %s\n",
                     [[[NSBundle mainBundle] infoDictionary][@"CFBundleShortVersionString"] UTF8String] ?: "?",
                     SDL_GetRevision());
        sa2ios_init(files.c_str(), docs.c_str(), caches.c_str(), bundle.c_str());
    }
    sa2ios_play_args args{};
    const int action = sa2ios_launcher_run(&args);
    if (action != 1) return 0;
    char session[4096] = {0};
    const int rc = sa2ios_play(&args, session, sizeof session);
    std::fprintf(stderr, "session ended: %d (%s)\n", rc, session);
    sa2ios_launcher_after_session(rc, session);
    return 0;
}
