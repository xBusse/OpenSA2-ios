// sa2_ios_session.mm: the iOS app's session (sa2_ios_session.h), host/launch's play path as the
// Android session takes it (host/android/native/sa2_android_session.cpp), with the one difference
// iOS forces: the game is not a process of its own but a thread of the app's (sa2_ios_game.h).
//
//  - The installation: the installer's config under the app's files folder (HOME, XDG_CONFIG_HOME
//    and XDG_DATA_HOME are set there by sa2ios_init), made by the installer run in-process
//    (sa2ios_install: host/install's sa2-install, its main renamed sa2_install_main), from the game
//    folder the user copied into Documents/Game (or chose elsewhere), or a ZIP of it.
//  - The session: Documents/Sessions/<stamp>, visible in the Files app, with the report
//    (report.txt, and Documents/last-session.txt), the console log (console.log: the game's, the
//    player's and SDL's stdout and stderr, which sa2_ios_console.mm captures), the records the
//    launcher's session keeps (game.runrec, player-report.runrec, d3d9gpu.runrec, counts.runrec,
//    input.log, ticks.tsv) and, with the session recorder on, the saves and config before and after
//    and the pads' log. The newest kKeepSessions are kept. The two FIFOs (the game's stream, the
//    keyboard and pads) are made under Library/Caches/SA2 instead, which the Files app never opens.
//    A file "running" in the session's folder marks a session in progress: the next launch reports
//    a session that still has it as one the app did not come back from (sa2ios_crashed_session).
//  - The game: sa2_game_main (harness/crt_probe.c) on its own thread, with the bundle's game.env and
//    the session's settings in the app's environment, exactly the launcher's (SA2_INSTALL,
//    SA2_VFS_WRITE_ROOT, SA2_EXE_KIND=shipped, SA2_REC_TRACE, SA2_REC_META, SA2_REC_COUNTS,
//    SA2_INPUT_DI_SOURCE, SA2_INPUT_DI_LOG, SA2_LAUNCH_TICKS) and the Android session's defaults
//    (SA2_REC_AUDIO_WATCH=0, SA2_REC_STORE_HASH_EVERY=64, full width, the HUD at 4:3, SA2_GUEST_CMDLINE
//    -r and the pad wait, since the touch overlay is slot 0's pad). The settings screen's settings
//    come after the defaults and Documents/game.env.extra's lines after those, as on Android. The
//    pace pipe's read end is the game's by its own number (SA2_REC_PACE_FD): one process, one table.
//    The session folder is the working folder while the game runs.
//  - The relay (host/launch/sa2_relay.h) hands the stream on to the player, paced (lead 1). Its
//    stall watch has no process to nudge here, so it only says what it sees.
//  - The player: host/player's main (sa2_player_main) on this, the main thread (SDL's), with the
//    launcher's play argv. pause-unfocused (host/player/tweaks/pause-unfocused.cpp) is always on:
//    iOS refuses GPU work from an app in the background, and SDL reports the window minimized there,
//    so the player holds in its event pump, the relay holds the game, and both go on when the app
//    is back, exactly where they were.
//  - The end: the player's end request (the in-game menu's End session, sa2ios_request_end) or the
//    game's end stops the game (sa2_ios_game_request_stop, the SIGTERM's stop), the relay ends with
//    the stream, and the player reads it to its END (cancelled kFeedGrace later if it has not). A
//    game that does not stop within kStopGrace is left where it is: there is no process to kill,
//    and the app is opened again for the next session in any case.
//
// The debug mode plays a recorded stream file through the player with no game (args.stream), the
// renderer's check on a device, as the Android app's.
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#include "sa2_ios_session.h"

#include "sa2_ios_console.h"
#include "sa2_ios_game.h"
#include "sa2_ios_ingame.h"
#include "sa2_ios_prof.h"

#include "sa2_config.h"
#include "sa2_install.h"
#include "sa2_launch_platform.h"
#include "sa2_platform.h"
#include "sa2_relay.h"
#include "sa2_session_files.h"
#include "sha256.h"

#include <SDL3/SDL.h>

#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <filesystem>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

int sa2_player_main(int argc, char** argv);       // host/player/player.cpp's main, renamed
int sa2_install_main(int argc, char** argv);      // host/install/sa2_install_cli.cpp's main, renamed

namespace {

constexpr size_t kRelayCap = 64u << 20;           // the launcher's
constexpr double kStopGrace = 10, kFeedGrace = 15;
constexpr int kKeepSessions = 5;

std::string g_files, g_docs, g_caches, g_bundle;
std::string g_report;                             // Documents/last-session.txt
std::string g_session_report;                     // <session>/report.txt
std::vector<std::string> g_lines;
std::mutex g_say;
std::atomic<bool> g_session_ran{false};
std::atomic<bool> g_end_asked{false};

void write_report_locked() {
    std::string text;
    for (const std::string& l : g_lines) text += l + "\n";
    if (!g_report.empty()) sa2p::write_file_atomic(g_report, text);
    if (!g_session_report.empty()) sa2p::write_file_atomic(g_session_report, text);
}

// One line of the session's report: in report.txt, last-session.txt and the console.
void say(const char* fmt, ...) __attribute__((format(printf, 1, 2)));
void say(const char* fmt, ...) {
    char buf[2048];
    va_list ap;
    va_start(ap, fmt);
    std::vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    std::lock_guard<std::mutex> hold(g_say);
    g_lines.emplace_back(buf);
    std::fprintf(stderr, "session: %s\n", buf);
    write_report_locked();
}

bool exists_file(const std::string& p) {
    sa2p::Stat s;
    return sa2p::stat_path(p, s) && s.is_file;
}
bool exists_dir(const std::string& p) {
    sa2p::Stat s;
    return sa2p::stat_path(p, s) && s.is_dir;
}

std::string stamp() {
    char buf[32];
    std::time_t t = std::time(nullptr);
    std::tm tm{};
    localtime_r(&t, &tm);
    std::strftime(buf, sizeof buf, "%Y%m%d-%H%M%S", &tm);
    return buf;
}

std::string sessions_root() { return g_docs + "/Sessions"; }

// A new session folder under Documents/Sessions, keeping the kKeepSessions - 1 newest before it.
std::string new_session(const std::string& suffix) {
    namespace fs = std::filesystem;
    const std::string root = sessions_root();
    sa2p::make_dirs(root);
    std::vector<std::string> names;
    sa2p::list_dir(root, names);
    std::sort(names.begin(), names.end());
    std::error_code ec;
    for (size_t i = 0; i + (kKeepSessions - 1) < names.size(); i++) fs::remove_all(root + "/" + names[i], ec);
    const std::string s = root + "/" + stamp() + suffix;
    return sa2p::make_dirs(s) ? s : "";
}

// The device, for session-info.json: what a bug report needs to know about the phone.
sa2s::KV device_facts() {
    sa2s::KV kv = sa2s::host_facts();
    char machine[64] = {0};
    size_t n = sizeof machine - 1;
    if (sysctlbyname("hw.machine", machine, &n, nullptr, 0) == 0 && machine[0]) kv.push_back({"model", machine});
    @autoreleasepool {
        UIDevice* d = [UIDevice currentDevice];
        kv.push_back({"system", std::string(d.systemName.UTF8String) + " " + d.systemVersion.UTF8String});
        NSProcessInfo* p = [NSProcessInfo processInfo];
        kv.push_back({"memory_bytes", std::to_string(p.physicalMemory)});
        kv.push_back({"cpus", std::to_string(p.activeProcessorCount)});
        kv.push_back({"low_power_mode", p.lowPowerModeEnabled ? "true" : "false"});
        const NSProcessInfoThermalState ts = p.thermalState;
        kv.push_back({"thermal_state", ts == NSProcessInfoThermalStateNominal ? "nominal"
                                       : ts == NSProcessInfoThermalStateFair  ? "fair"
                                       : ts == NSProcessInfoThermalStateSerious ? "serious" : "critical"});
        NSDictionary* info = [[NSBundle mainBundle] infoDictionary];
        NSString* ver = info[@"CFBundleShortVersionString"];
        NSString* build = info[@"CFBundleVersion"];
        if (ver) kv.push_back({"app_version", std::string(ver.UTF8String) + (build ? std::string(" (") + build.UTF8String + ")" : "")});
    }
    return kv;
}

void write_session_info(const std::string& session, const sa2s::KV& run) {
    sa2s::KV info = {{"schema", "sa2-session-info/v1"}};
    info.insert(info.end(), run.begin(), run.end());
    info.push_back({"build:", sa2s::json_object({{"install_table", sa2_install_table().id}})});
    info.push_back({"platform:", sa2s::json_object(device_facts())});
    sa2p::write_file_atomic(session + "/session-info.json", sa2s::json_object(info) + "\n");
}

using EnvList = std::vector<std::pair<std::string, std::string>>;

const std::string* env_find(const EnvList& env, const std::string& k) {
    for (const auto& e : env)
        if (e.first == k) return &e.second;
    return nullptr;
}

void env_set(EnvList& env, const std::string& k, const std::string& v) {
    for (auto& e : env)
        if (e.first == k) {
            e.second = v;
            return;
        }
    env.emplace_back(k, v);
}

void env_drop(EnvList& env, const char* k) {
    env.erase(std::remove_if(env.begin(), env.end(), [k](const auto& e) { return e.first == k; }), env.end());
}

// The SA2_ lines of a settings file (the bundle's game.env, Documents/game.env.extra): "#" lines and
// blank ones skipped; a line that is no SA2_K=V setting goes to `bad`.
bool read_settings(const std::string& path, EnvList& out, std::vector<std::string>* bad) {
    std::string text;
    if (!sa2p::read_file(path, text, 1u << 20)) return false;
    size_t at = 0;
    while (at < text.size()) {
        size_t nl = text.find('\n', at);
        std::string line = text.substr(at, nl == std::string::npos ? std::string::npos : nl - at);
        at = nl == std::string::npos ? text.size() : nl + 1;
        if (!line.empty() && line.back() == '\r') line.pop_back();
        if (line.empty() || line[0] == '#') continue;
        const size_t eq = line.find('=');
        if (eq == std::string::npos || line.compare(0, 4, "SA2_") != 0) {
            if (bad) bad->push_back(line);
            continue;
        }
        out.emplace_back(line.substr(0, eq), line.substr(eq + 1));
    }
    return true;
}

// The settings that are the player's, not the game's (the Android session's player_setting). In one
// process they share the environment; they are said apart in the report, and the game ignores them.
bool player_setting(const std::string& k) {
    return k == "SA2_PLAYER_PROF" || k == "SA2_PLAYER_PROF_OUT" || k == "SA2_PLAYER_PICTURE_Y" || k == "SA2_PAD_MAP" ||
           k.compare(0, 10, "SA2_TOUCH_") == 0;
}

// ---------------------------------------------------------------- full width (as Android's)

uint32_t whole(const std::string& v) {
    if (v.empty() || v.size() > 5 || v.find_first_not_of("0123456789") != std::string::npos) return 0;
    return uint32_t(std::strtoul(v.c_str(), nullptr, 10));
}

bool parse_size(const std::string& v, uint32_t& w, uint32_t& h) {
    const size_t x = v.find_first_of("xX");
    if (x == std::string::npos) return false;
    w = whole(v.substr(0, x));
    h = whole(v.substr(x + 1));
    return w >= 320 && w <= 16384 && h >= 320 && h <= 16384;
}

// host/android/native/sa2_android_session.cpp full_width, the same rule: the screen's size unless the
// settings screen set SA2_PLAY_RES, or game.env.extra set SA2_PLAY_RES (an "hNNN" one resolved here
// at the screen's aspect) or SA2_PLAY_ASPECT alone. What was decided, in words.
std::string full_width(EnvList& env, const std::string& screen, bool settings_res, bool extra_res, bool extra_aspect) {
    uint32_t sw = 0, sh = 0;
    const bool have = parse_size(screen, sw, sh);
    const std::string on = have ? "screen " + screen : "no screen size";
    if (extra_aspect && !extra_res) {
        env_drop(env, "SA2_PLAY_RES");
        return on + "; SA2_PLAY_ASPECT=" + *env_find(env, "SA2_PLAY_ASPECT") + " (game.env.extra)";
    }
    const std::string* res = env_find(env, "SA2_PLAY_RES");
    if (extra_res && res && res->size() > 1 && (res->at(0) == 'h' || res->at(0) == 'H')) {
        const uint32_t lines = whole(res->substr(1));
        const std::string asked = *res;
        if (!have || lines < 320 || lines > 16384) {
            env_drop(env, "SA2_PLAY_RES");
            return on + "; SA2_PLAY_RES=" + asked + " (game.env.extra) not applied, so the config's own size";
        }
        const uint64_t w = (uint64_t(lines) * sw + sh / 2) / sh;
        if (w < 320 || w > 16384) {
            env_drop(env, "SA2_PLAY_RES");
            return on + "; SA2_PLAY_RES=" + asked + " (game.env.extra) gives a width outside 320 to 16384";
        }
        env_set(env, "SA2_PLAY_RES", std::to_string(w) + "x" + std::to_string(lines));
        return on + "; SA2_PLAY_RES=" + asked + " (game.env.extra): " + *env_find(env, "SA2_PLAY_RES");
    }
    if (extra_res) return on + "; SA2_PLAY_RES=" + (res ? *res : std::string()) + " (game.env.extra)";
    if (res) return on + "; SA2_PLAY_RES=" + *res + (settings_res ? " (the settings screen)" : " (the screen)");
    return on + "; the config's own size" + (have ? " (the screen is no wider than 4:3)" : "");
}

// ---------------------------------------------------------------- the process's environment

// Every SA2_ variable of the app's environment unset, then `env`'s set: the game and the player read
// the one environment the app has.
void apply_environment(const EnvList& env) {
    std::vector<std::string> gone;
    for (const auto& kv : sa2l::environment())
        if (kv.first.compare(0, 4, "SA2_") == 0) gone.push_back(kv.first);
    for (const std::string& k : gone) unsetenv(k.c_str());
    for (const auto& kv : env) setenv(kv.first.c_str(), kv.second.c_str(), 1);
}

// SA2_TWEAKS with `name` added (once), comma-separated.
std::string with_tweak(const std::string* tweaks, const char* name) {
    std::string v = tweaks ? *tweaks : "";
    size_t at = 0;
    while (at <= v.size()) {
        const size_t comma = v.find(',', at);
        if (v.compare(at, (comma == std::string::npos ? v.size() : comma) - at, name) == 0) return v;
        if (comma == std::string::npos) break;
        at = comma + 1;
    }
    return v.empty() ? std::string(name) : v + "," + name;
}

int run_player(const std::vector<std::string>& args) {
    std::vector<std::string> copy = args;
    std::vector<char*> argv;
    for (std::string& a : copy) argv.push_back(a.data());
    argv.push_back(nullptr);
    std::string line;
    for (const std::string& a : args) line += a + " ";
    std::fprintf(stderr, "session: player: %s\n", line.c_str());
    return sa2_player_main(int(argv.size() - 1), argv.data());
}

// The player's own outputs, as the Android session's player_env gives them.
void player_env(const std::string& session) {
    setenv("SA2_PLAY_OUT", (session + "/play").c_str(), 1);
    setenv("SA2_D3D9GPU_REPORT", (session + "/d3d9gpu.runrec").c_str(), 1);
    setenv("SDL_NO_SIGNAL_HANDLERS", "1", 1);
    sa2p::make_dirs(session + "/play");
}

// The first line of `path` that holds `needle`, said after `prefix`, while the player runs, for at
// most a minute (the Android session's relay_line): a line the report should carry from the log.
void relay_line(const std::string& path, const char* needle, const char* prefix, const std::atomic<bool>& done) {
    const double t0 = sa2p::monotonic_seconds();
    while (!done.load() && sa2p::monotonic_seconds() - t0 < 60) {
        std::string log;
        if (sa2p::read_file(path, log)) {
            const size_t at = log.find(needle);
            const size_t nl = at == std::string::npos ? at : log.find('\n', at);
            if (nl != std::string::npos) {
                say("%s%s", prefix, log.substr(at, nl - at).c_str());
                return;
            }
        }
        sa2l::sleep_ms(250);
    }
}

// A descriptor handed to the player, which owns it from then on (the Android session's Held).
struct Held {
    int fd = -1;
    dev_t dev = 0;
    ino_t ino = 0;
    void hold(intptr_t f) {
        fd = int(f);
        struct stat st;
        if (fstat(fd, &st) == 0) {
            dev = st.st_dev;
            ino = st.st_ino;
        }
    }
    void close_if_ours() {
        struct stat st;
        if (fd >= 0 && fstat(fd, &st) == 0 && st.st_dev == dev && st.st_ino == ino) close(fd);
        fd = -1;
    }
};

// The session's beginning, said: the report files and the console's file.
bool begin_session(const std::string& session) {
    {
        std::lock_guard<std::mutex> hold(g_say);
        g_lines.clear();
        g_session_report = session + "/report.txt";
    }
    sa2ios_console_switch((session + "/console.log").c_str(), 1);
    sa2p::write_file_atomic(session + "/running", sa2p::now_utc_iso8601() + "\n");
    return true;
}

void end_session(const std::string& session) {
    std::remove((session + "/running").c_str());
    sa2ios_console_switch(nullptr, 0);
}

// The orientations SDL's view controller allows (SDL_HINT_ORIENTATIONS).
void set_orientation(const std::string& o) {
    const char* hint = o == "portrait" ? "Portrait PortraitUpsideDown"
                     : o == "auto"     ? "LandscapeLeft LandscapeRight Portrait PortraitUpsideDown"
                                       : "LandscapeLeft LandscapeRight";
    SDL_SetHint(SDL_HINT_ORIENTATIONS, hint);
}

// ---------------------------------------------------------------- the debug mode: a stream file

int play_stream(const sa2ios_play_args& a, std::string& session) {
    session = new_session("-stream");
    if (session.empty()) {
        say("FAIL cannot create a session folder under %s", sessions_root().c_str());
        return 5;
    }
    begin_session(session);
    say("sa2recomp (iOS) stream");
    say("session %s", session.c_str());
    if (!exists_file(a.stream)) {
        say("FAIL no stream file at %s", a.stream);
        end_session(session);
        return 4;
    }
    say("mode stream %s", a.stream);
    EnvList env;
    for (int i = 0; i < a.setting_count; i++) {
        const std::string kv = a.settings[i];
        const size_t eq = kv.find('=');
        if (eq != std::string::npos && player_setting(kv.substr(0, eq))) {
            env_set(env, kv.substr(0, eq), kv.substr(eq + 1));
            say("settings: %s", kv.c_str());
        }
    }
    apply_environment(env);
    player_env(session);
    set_orientation(a.orientation ? a.orientation : "");
    std::vector<std::string> args = {"sa2_player", a.stream, "--stage", "3", "--allow-truncated",
                                     "--report", session + "/player-report.runrec"};
    if (a.pace) args.push_back("--pace");
    if (a.audio) args.push_back("--audio");
    if (a.max_frames && *a.max_frames) {
        args.push_back("--max-frames");
        args.push_back(a.max_frames);
    }
    Sa2IosIngame ig;
    ig.console_path = session + "/console.log";
    ig.session = session;
    ig.menu_button = a.menu_button != 0;
    ig.hud = a.debug_hud != 0;
    ig.status = [] { return std::string("stream playback"); };
    sa2ios_ingame_begin(ig);
    const int rc = run_player(args);
    sa2ios_ingame_end();
    say("player exit %d", rc);
    if (rc == 0) say("OK the stream played");
    else say("FAIL the player exited %d (see console.log)", rc);
    end_session(session);
    return rc;
}

// ---------------------------------------------------------------- a game session

int play_game(const sa2ios_play_args& a, std::string& session) {
    session = new_session("");
    if (session.empty()) {
        say("FAIL cannot create a session folder under %s", sessions_root().c_str());
        return 5;
    }
    begin_session(session);
    say("sa2recomp (iOS) play");
    say("session %s", session.c_str());
    auto fail = [&](int code, const std::string& why) {
        say("FAIL %s", why.c_str());
        end_session(session);
        return code;
    };

    // The installation.
    const std::string cfg_path = sa2_config_path();
    std::string text, why;
    Sa2Config cfg;
    if (cfg_path.empty() || !sa2p::read_file(cfg_path, text))
        return fail(4, "no installation: " + cfg_path + " does not exist (the setup screen installs it)");
    if (!sa2_config_parse(text, cfg, &why)) return fail(5, cfg_path + ": " + why);
    const Sa2InstallTable& table = sa2_install_table();
    if (cfg.table_id != table.id || cfg.receipt_sha256 != table.receipt_sha256)
        return fail(3, "the installation was verified under another hash table (" + cfg.table_id + "); install again");
    if (!exists_dir(cfg.read_root) || !exists_file(cfg.exe) || cfg.overlay.empty() || cfg.overlay[0] != '/')
        return fail(3, "the installation names a game folder or executable that does not exist (" + cfg.read_root +
                           ", " + cfg.exe + "); install again");
    if (!sa2p::make_dirs(cfg.overlay)) return fail(5, "cannot create the overlay " + cfg.overlay);
    say("game folder %s", cfg.read_root.c_str());

    // The FIFOs and pipes. The FIFOs live under Library/Caches, never in Documents.
    const std::string fifo_dir = g_caches + "/fifo-" + stamp();
    std::error_code ec;
    std::filesystem::remove_all(fifo_dir, ec);
    if (!sa2p::make_dirs(fifo_dir)) return fail(5, "cannot create " + fifo_dir);
    const std::string game_fifo = fifo_dir + "/game.fifo", input_fifo = fifo_dir + "/input.fifo";
    if (!sa2l::make_fifo(game_fifo, &why) || !sa2l::make_fifo(input_fifo, &why)) return fail(5, why);
    sa2l::Fd relay_in = sa2l::open_fifo_reader(game_fifo, &why);
    sa2l::Fd keys_fd = relay_in == sa2l::kNoFd ? sa2l::kNoFd : sa2l::open_fifo_holder(input_fifo, &why);
    sa2l::Fd video_r = sa2l::kNoFd, video_w = sa2l::kNoFd, cancel_r = sa2l::kNoFd, cancel_w = sa2l::kNoFd,
             end_r = sa2l::kNoFd, end_w = sa2l::kNoFd, game_end_r = sa2l::kNoFd, game_end_w = sa2l::kNoFd;
    if (keys_fd == sa2l::kNoFd || !sa2l::make_pipe(video_r, video_w, &why) ||
        !sa2l::make_pipe(cancel_r, cancel_w, &why) || !sa2l::make_pipe(end_r, end_w, &why) ||
        !sa2l::make_pipe(game_end_r, game_end_w, &why))
        return fail(5, why);
    sa2l::Fd pace_r = sa2l::kNoFd, pace_w = sa2l::kNoFd;
    if (a.pace && !sa2l::make_pipe(pace_r, pace_w, &why)) return fail(5, why);

    // The game's settings.
    EnvList genv;
    std::vector<std::string> bad;
    if (!read_settings(g_bundle + "/game.env", genv, &bad))
        return fail(5, "no game.env in the app (" + g_bundle + "/game.env): the app was built without the game's settings");
    for (const std::string& b : bad) say("game.env: not an SA2_ setting, not used: %s", b.c_str());
    // The Android session's defaults, which the settings screen's and game.env.extra's replace.
    env_set(genv, "SA2_REC_AUDIO_WATCH", "0");
    env_set(genv, "SA2_REC_STORE_HASH_EVERY", "64");
    const std::string screen = a.screen_w > 0 && a.screen_h > 0
                                   ? std::to_string(a.screen_w) + "x" + std::to_string(a.screen_h) : "";
    uint32_t sw = 0, sh = 0;
    if (parse_size(screen, sw, sh) && uint64_t(sw) * 3 > uint64_t(sh) * 4) env_set(genv, "SA2_PLAY_RES", screen);
    env_set(genv, "SA2_PLAY_HUD43", "1");
    bool settings_res = false;
    for (int i = 0; i < a.setting_count; i++) {
        const std::string kv = a.settings[i];
        const size_t eq = kv.find('=');
        if (eq == std::string::npos || kv.compare(0, 4, "SA2_") != 0) {
            say("settings: not SA2_K=V, not used: %s", kv.c_str());
            continue;
        }
        env_set(genv, kv.substr(0, eq), kv.substr(eq + 1));
        settings_res |= kv.compare(0, eq, "SA2_PLAY_RES") == 0;
        say("settings: %s", kv.c_str());
    }
    bool extra_res = false, extra_aspect = false;
    {
        EnvList extra;
        std::vector<std::string> extra_bad;
        if (read_settings(g_docs + "/game.env.extra", extra, &extra_bad)) {
            for (const std::string& b : extra_bad) say("game.env.extra: not an SA2_ setting, not used: %s", b.c_str());
            for (const auto& kv : extra) {
                env_set(genv, kv.first, kv.second);
                extra_res |= kv.first == "SA2_PLAY_RES";
                extra_aspect |= kv.first == "SA2_PLAY_ASPECT";
                say("game.env.extra: %s=%s", kv.first.c_str(), kv.second.c_str());
            }
        }
    }
    say("widescreen: %s", full_width(genv, screen, settings_res, extra_res, extra_aspect).c_str());
    for (const auto& kv : genv)
        if (player_setting(kv.first)) say("player: %s=%s (the player's setting)", kv.first.c_str(), kv.second.c_str());
    if (!a.audio) env_drop(genv, "SA2_REC_AUDIO");
    // pause-unfocused is always on here (the header): the player holds while the app is away.
    env_set(genv, "SA2_TWEAKS", with_tweak(env_find(genv, "SA2_TWEAKS"), "pause-unfocused"));
    env_set(genv, "SA2_INSTALL", cfg.read_root);
    env_set(genv, "SA2_VFS_WRITE_ROOT", cfg.overlay);
    env_set(genv, "SA2_EXE_KIND", "shipped");
    env_set(genv, "SA2_REC_TRACE", game_fifo);
    env_set(genv, "SA2_REC_META", "{\"host\":\"sdl3-gpu\",\"interactive\":true,\"runner\":\"host/ios\","
                                  "\"scene\":\"boot\",\"selftest\":false}");
    env_set(genv, "SA2_REC_COUNTS", session + "/counts.runrec");
    env_set(genv, "SA2_INPUT_DI_SOURCE", input_fifo);
    env_set(genv, "SA2_INPUT_DI_LOG", session + "/input.log");
    env_set(genv, "SA2_LAUNCH_TICKS", session + "/ticks.tsv");
    if (pace_r != sa2l::kNoFd) env_set(genv, "SA2_REC_PACE_FD", std::to_string(pace_r));
    else env_drop(genv, "SA2_REC_PACE_FD");
    env_set(genv, "SA2_GUEST_CMDLINE", "-r");
    env_set(genv, "SA2_INPUT_PAD_WAIT_MS", "10000");
    const std::string* record_asked = env_find(genv, "SA2_RECORD_SESSION");
    const bool recording = record_asked && *record_asked == "1";
    env_drop(genv, "SA2_RECORD_SESSION");
    say("session recorder: %s", recording ? "on (Debug > Record sessions)" : "off");
    if (recording) env_set(genv, "SA2_INPUT_PAD_LOG", session + "/pad.log");
    const sa2s::KV subs = {{session, "<session>"}, {cfg.read_root, "<game>"}, {cfg.overlay, "<overlay>"},
                           {g_files, "<files>"}, {g_docs, "<documents>"}, {g_caches, "<caches>"}};
    sa2s::KV run = {{"runner", "host/ios"}, {"mode", "play"}, {"host", "sdl3-gpu (Metal)"},
                    {"started", sa2p::now_utc_iso8601()}, {"screen", screen},
                    {"orientation", a.orientation && *a.orientation ? a.orientation : "landscape"},
                    {"paced", a.pace ? "true" : "false"}, {"sound", a.audio ? "true" : "false"}};
    for (int i = 0; i < a.setting_count; i++) {
        const std::string kv = a.settings[i];
        const size_t eq = kv.find('=');
        if (eq != std::string::npos) run.push_back({"setting " + kv.substr(0, eq), kv.substr(eq + 1)});
    }
    write_session_info(session, run);
    sa2p::write_file_atomic(session + "/game-env.txt", sa2s::env_text(genv, subs));
    if (recording)
        for (const auto& [rel, dir] : {std::pair<const char*, const char*>{sa2s::kSaveDir, "/start-saves"},
                                       {sa2s::kConfigDir, "/start-config"}}) {
            const sa2s::Snapshot s = sa2s::snapshot(cfg.read_root, cfg.overlay, rel, false, session + dir);
            if (!s.error.empty()) say("session recorder: %s", s.error.c_str());
        }

    // The environment: the game's settings and the player's, in the one the app has.
    apply_environment(genv);
    player_env(session);
    set_orientation(a.orientation ? a.orientation : "");
    if (chdir(session.c_str()) != 0) say("the session folder could not be made the working folder: %s", strerror(errno));

    // The game.
    const std::vector<std::string> gargv = {"sa2-game", cfg.exe, "--json", session + "/game.runrec", "--timeout", "0"};
    std::vector<const char*> gptrs;
    for (const std::string& s : gargv) gptrs.push_back(s.c_str());
    const int started = sa2_ios_game_start(int(gptrs.size()), gptrs.data(), int(game_end_w),
                                           (session + "/game-end.txt").c_str(), 0);
    if (started != 0) {
        return fail(5, started == -2 ? "a game has run in this app already: quit the app and open it again"
                                     : std::string("cannot start the game's thread: ") + strerror(errno));
    }
    say("game: started on its own thread");

    // The relay.
    std::atomic<bool> game_alive{true}, player_done{false};
    sa2l::Relay relay(relay_in, video_w, a.pace ? 1u : 0u, kRelayCap, pace_w);
    relay.nudge = [] { return false; };          // no process to nudge (the header)
    relay.note = [](const std::string& line) { say("%s", line.c_str()); };
    std::thread relay_thread([&] {
        pthread_setname_np("sa2-relay");
        relay.run(game_alive);
    });

    // The report's lines from the console (the game's full width and tweaks, the player's).
    const std::string console = session + "/console.log";
    const std::string* tweaks = env_find(genv, "SA2_TWEAKS");
    std::thread ws_thread([&] {
        if (env_find(genv, "SA2_PLAY_RES") || env_find(genv, "SA2_PLAY_ASPECT"))
            relay_line(console, "widescreen: ", "game: ", player_done);
    });
    std::thread tweaks_thread([&] {
        if (tweaks && !tweaks->empty()) relay_line(console, "sa2 tweaks: ", "game: ", player_done);
    });
    std::thread host_tweaks_thread([&] {
        if (tweaks && !tweaks->empty()) relay_line(console, "sa2 host tweaks (player): ", "player: ", player_done);
    });

    // The speed line every 30 s (frames handed on a second), as the Android session's perf line says it.
    // With the sampler on (the default; SA2_IOS_PROF=0 in game.env.extra turns it off) the 30 s are a
    // window of sa2_ios_prof.h: where every thread's time went, in <session>/prof.txt, and a line.
    const std::string* prof_env = env_find(genv, "SA2_IOS_PROF");
    const bool prof_on = !(prof_env && *prof_env == "0");
    std::thread perf_thread([&] {
        pthread_setname_np("sa2-perf");
        uint64_t last = 0;
        double t_last = sa2p::monotonic_seconds();
        while (!player_done.load()) {
            std::string prof_line;
            if (prof_on) prof_line = sa2ios::prof_window(30.0, 10, session + "/prof.txt", player_done);
            else
                for (int i = 0; i < 300 && !player_done.load(); i++) sa2l::sleep_ms(100);
            if (player_done.load()) break;
            const double now = sa2p::monotonic_seconds();
            const uint64_t f = relay.frames_out();
            NSProcessInfoThermalState ts = [NSProcessInfo processInfo].thermalState;
            say("perf: %.1f frames/s over %.0f s; thermal state %s", double(f - last) / (now - t_last), now - t_last,
                ts == NSProcessInfoThermalStateNominal ? "nominal" : ts == NSProcessInfoThermalStateFair ? "fair"
                : ts == NSProcessInfoThermalStateSerious ? "serious" : "critical");
            if (!prof_line.empty()) say("%s", prof_line.c_str());
            last = f;
            t_last = now;
        }
    });

    // The watch: the game's end or the player's end request stops the game; the player is then given
    // kFeedGrace to read the stream to its END.
    std::string ended_by, stop_how;
    std::thread watch([&] {
        pthread_setname_np("sa2-watch");
        while (!player_done.load()) {
            if (sa2l::wait_readable(game_end_r, 0) > 0) {
                int code = 0;
                const int how = sa2_ios_game_ended(&code);
                ended_by = std::string("the game ended (") + (how == SA2_IOS_GAME_EXITED ? "exit " : "returned ") +
                           std::to_string(code) + ")";
                break;
            }
            if (sa2l::wait_readable(end_r, 20) > 0) {
                char byte = 0;
                ended_by = sa2l::read_some(end_r, &byte, 1) == 1 ? "the player asked for the end" : "the player ended";
                break;
            }
        }
        if (ended_by.empty()) ended_by = "the player ended";
        relay.end_watch();
        if (sa2_ios_game_ended(nullptr) == SA2_IOS_GAME_RUNNING) {
            sa2_ios_game_request_stop();
            const double t0 = sa2p::monotonic_seconds();
            while (sa2_ios_game_ended(nullptr) == SA2_IOS_GAME_RUNNING && sa2p::monotonic_seconds() - t0 < kStopGrace)
                sa2l::sleep_ms(50);
            stop_how = sa2_ios_game_ended(nullptr) == SA2_IOS_GAME_RUNNING
                           ? "nothing: it did not stop in time, and is left (open the app again to play again)"
                           : "its stop (WM_QUIT at its next keyboard poll)";
        } else {
            stop_how = "nothing (it had ended by itself)";
        }
        game_alive = false;
        if (!player_done.load())
            say("%s; the game is stopped by %s; the player has %.0f s to read its END", ended_by.c_str(),
                stop_how.c_str(), kFeedGrace);
        const double t0 = sa2p::monotonic_seconds();
        while (!player_done.load() && sa2p::monotonic_seconds() - t0 < kFeedGrace) sa2l::sleep_ms(50);
        if (!player_done.load()) {
            say("the player did not reach the END in %.0f s: cancelled", kFeedGrace);
            const char byte = 1;
            sa2l::write_all(cancel_w, &byte, 1);
        }
    });

    // The player, here.
    Held held_video, held_cancel, held_end;
    held_video.hold(video_r);
    held_cancel.hold(cancel_r);
    held_end.hold(end_w);
    std::vector<std::string> args = {"sa2_player", "--interactive",
                                     "--video-fd", std::to_string(video_r),
                                     "--cancel-fd", std::to_string(cancel_r),
                                     "--end-fd", std::to_string(end_w),
                                     "--stage", "3", "--report", session + "/player-report.runrec",
                                     "--report-every", "600", "--input-path", input_fifo};
    if (a.pace) args.push_back("--pace");
    if (a.audio) args.push_back("--audio");
    Sa2IosIngame ig;
    ig.console_path = console;
    ig.session = session;
    ig.menu_button = a.menu_button != 0;
    ig.hud = a.debug_hud != 0;
    ig.status = [&relay] {
        int code = 0;
        const int how = sa2_ios_game_ended(&code);
        char line[160];
        std::snprintf(line, sizeof line, "frames %llu  game %s", (unsigned long long)relay.frames_out(),
                      how == SA2_IOS_GAME_RUNNING ? "running" : ("ended " + std::to_string(code)).c_str());
        return std::string(line);
    };
    g_end_asked = false;
    sa2ios_ingame_begin(ig);
    const int rc = run_player(args);
    sa2ios_ingame_end();
    player_done = true;
    held_video.close_if_ours();
    held_cancel.close_if_ours();
    held_end.close_if_ours();
    ws_thread.join();
    tweaks_thread.join();
    host_tweaks_thread.join();
    perf_thread.join();
    watch.join();
    relay_thread.join();
    const sa2l::RelayStats rs = relay.stats();
    sa2l::close_fd(cancel_w);
    sa2l::close_fd(end_r);
    sa2l::close_fd(keys_fd);
    sa2l::close_fd(relay_in);
    sa2l::close_fd(game_end_r);
    if (recording) {
        for (const auto& [rel, dir] : {std::pair<const char*, const char*>{sa2s::kSaveDir, "/end-saves"},
                                       {sa2s::kConfigDir, "/end-config"}}) {
            const sa2s::Snapshot s = sa2s::snapshot(cfg.read_root, cfg.overlay, rel, false, session + dir);
            if (!s.error.empty()) say("session recorder: %s", s.error.c_str());
        }
    }
    int code = 0;
    const int how = sa2_ios_game_ended(&code);
    say("ended: %s; the game stopped by %s (%s); the player exited %d", ended_by.c_str(), stop_how.c_str(),
        how == SA2_IOS_GAME_RUNNING ? "still running" : ("code " + std::to_string(code)).c_str(), rc);
    say("relay: %llu frames in, %llu out, %llu bytes%s", (unsigned long long)rs.frames_in,
        (unsigned long long)rs.frames_out, (unsigned long long)rs.bytes_in,
        rs.framing_problem.empty() ? "" : (", " + rs.framing_problem).c_str());
    for (const std::string& line : sa2l::relay_report(rs, game_fifo + ".status")) say("%s", line.c_str());
    if (rs.frames_in == 0) say("FAIL the game presented nothing: see console.log");
    else if (rc == 0) say("OK the session ended");
    else say("FAIL the player exited %d: see console.log", rc);
    if (chdir(g_files.c_str()) != 0) {}
    std::filesystem::remove_all(fifo_dir, ec);
    end_session(session);
    return rc;
}

// ---------------------------------------------------------------- the installation

bool holds_game(const std::string& dir) {
    // The executable, case-blind as the installer and the runtime match names.
    std::vector<std::string> names;
    if (!sa2p::list_dir(dir, names)) return false;
    for (const std::string& n : names)
        if (sa2_install_fold(n) == "sonic2app.exe") return true;
    return false;
}

}  // namespace

// ================================================================ the C interface

extern "C" void sa2ios_init(const char* files, const char* documents, const char* caches, const char* bundle) {
    g_files = files ? files : "";
    g_docs = documents ? documents : "";
    g_caches = caches ? caches : "";
    g_bundle = bundle ? bundle : "";
    g_report = g_docs + "/last-session.txt";
    sa2p::make_dirs(g_files);
    sa2p::make_dirs(g_files + "/config");
    sa2p::make_dirs(g_files + "/data");
    sa2p::make_dirs(g_caches);
    sa2p::make_dirs(g_docs + "/Game");
    sa2p::make_dirs(sessions_root());
    // The installer's and the session's folders (host/install/sa2_platform_posix.cpp): the app's own.
    setenv("HOME", g_files.c_str(), 1);
    setenv("XDG_CONFIG_HOME", (g_files + "/config").c_str(), 1);
    setenv("XDG_DATA_HOME", (g_files + "/data").c_str(), 1);
    setenv("TMPDIR", g_caches.c_str(), 1);
    // A pipe whose reader has gone is an error to the writer here, never the app's end: the game
    // and the player share the one process (the launcher's ignore_broken_pipes).
    sa2l::ignore_broken_pipes();
    // A note to read in the game's documents folder.
    const std::string readme = g_docs + "/Game/Put the game here.txt";
    if (!exists_file(readme))
        sa2p::write_file_atomic(readme,
            "Copy your own Sonic Adventure 2 (the 2012 PC release, from Steam) here: the contents of its folder,\n"
            "the one that holds sonic2app.exe and resource/, or that folder itself. Then open SA2 Recompiled and\n"
            "choose Verify the game files. The game folder is only read, never written.\n");
}

extern "C" int sa2ios_install_status(char* game, size_t game_n, char* overlay, size_t overlay_n, char* why, size_t why_n) {
    auto out = [](char* buf, size_t n, const std::string& s) {
        if (buf && n) std::snprintf(buf, n, "%s", s.c_str());
    };
    out(game, game_n, "");
    out(overlay, overlay_n, "");
    const std::string cfg_path = sa2_config_path();
    std::string text, err;
    Sa2Config cfg;
    if (cfg_path.empty() || !sa2p::read_file(cfg_path, text)) {
        out(why, why_n, "not installed");
        return 0;
    }
    if (!sa2_config_parse(text, cfg, &err)) {
        out(why, why_n, "the installation's config does not read: " + err);
        return -1;
    }
    out(game, game_n, cfg.read_root);
    out(overlay, overlay_n, cfg.overlay);
    const Sa2InstallTable& table = sa2_install_table();
    if (cfg.table_id != table.id || cfg.receipt_sha256 != table.receipt_sha256) {
        out(why, why_n, "verified under another hash table (" + cfg.table_id + "): verify again");
        return -1;
    }
    if (!exists_dir(cfg.read_root) || !exists_file(cfg.exe)) {
        out(why, why_n, "the game folder it names is gone (" + cfg.read_root + "): verify again");
        return -1;
    }
    out(why, why_n, "ready");
    return 1;
}

extern "C" int sa2ios_install(const char* kind, const char* path, const char* log_path) {
    const std::string k = kind ? kind : "folder";
    std::vector<std::string> args = {"sa2-install", "--source", k, path ? path : "", "--yes", "--threads", "0"};
    if (log_path && *log_path) {
        args.push_back("--record");
        args.push_back(std::string(log_path) + ".runrec");
        sa2ios_console_switch(log_path, 1);
    }
    std::vector<char*> argv;
    for (std::string& a : args) argv.push_back(a.data());
    argv.push_back(nullptr);
    std::fprintf(stderr, "sa2-install --source %s %s --yes\n", k.c_str(), path ? path : "");
    const int rc = sa2_install_main(int(argv.size() - 1), argv.data());
    std::fprintf(stderr, "sa2-install exited %d\n", rc);
    if (log_path && *log_path) sa2ios_console_switch(nullptr, 0);
    return rc;
}

extern "C" int sa2ios_find_game_folder(const char* root, char* out, size_t n) {
    if (!root) return 0;
    const std::string r = root;
    if (holds_game(r)) {
        std::snprintf(out, n, "%s", r.c_str());
        return 1;
    }
    std::vector<std::string> names;
    if (!sa2p::list_dir(r, names)) return 0;
    std::string found;
    int count = 0;
    for (const std::string& name : names) {
        const std::string d = r + "/" + name;
        if (exists_dir(d) && holds_game(d)) {
            found = d;
            count++;
        }
    }
    if (count != 1) return 0;
    std::snprintf(out, n, "%s", found.c_str());
    return 1;
}

extern "C" int sa2ios_play(const sa2ios_play_args* args, char* session, size_t session_n) {
    if (session && session_n) session[0] = 0;
    if (!args) return 2;
    if (g_session_ran.exchange(true)) {
        say("FAIL a session has run in this app already: quit the app and open it again");
        return 6;
    }
    std::string s;
    const int rc = args->stream && *args->stream ? play_stream(*args, s) : play_game(*args, s);
    if (session && session_n) std::snprintf(session, session_n, "%s", s.c_str());
    return rc;
}

extern "C" int sa2ios_session_has_run(void) { return g_session_ran.load() ? 1 : 0; }

extern "C" void sa2ios_report_path(char* out, size_t n) { std::snprintf(out, n, "%s", g_report.c_str()); }

extern "C" void sa2ios_request_end(void) {
    // As the window's close: SDL_EVENT_QUIT, which the player takes as its end request (--end-fd).
    g_end_asked = true;
    SDL_Event e;
    SDL_zero(e);
    e.type = SDL_EVENT_QUIT;
    SDL_PushEvent(&e);
}

extern "C" void sa2ios_crashed_session(char* out, size_t n) {
    if (out && n) out[0] = 0;
    std::vector<std::string> names;
    if (!sa2p::list_dir(sessions_root(), names)) return;
    std::sort(names.begin(), names.end());
    for (auto it = names.rbegin(); it != names.rend(); ++it) {
        const std::string d = sessions_root() + "/" + *it;
        if (!exists_dir(d)) continue;
        if (exists_file(d + "/running")) {
            std::remove((d + "/running").c_str());
            std::snprintf(out, n, "%s", d.c_str());
        }
        return;      // only the newest session is looked at
    }
}

extern "C" int sa2ios_export_saves(const char* dest, char* why, size_t why_n) {
    char game[4096], overlay[4096], w[512];
    if (sa2ios_install_status(game, sizeof game, overlay, sizeof overlay, w, sizeof w) == 0) {
        std::snprintf(why, why_n, "%s", w);
        return -1;
    }
    const std::vector<sa2s::SeenFile> files = sa2s::seen_files(game, overlay, sa2s::kSaveDir, false);
    if (!sa2p::make_dirs(dest)) {
        std::snprintf(why, why_n, "cannot create %s", dest);
        return -1;
    }
    int copied = 0;
    for (const sa2s::SeenFile& f : files) {
        std::error_code ec;
        std::filesystem::copy_file(f.path, std::string(dest) + "/" + f.name,
                                   std::filesystem::copy_options::overwrite_existing, ec);
        if (ec) {
            std::snprintf(why, why_n, "%s: %s", f.name.c_str(), ec.message().c_str());
            return -1;
        }
        copied++;
    }
    return copied;
}

extern "C" int sa2ios_import_saves(const char* src, char* why, size_t why_n) {
    char game[4096], overlay[4096], w[512];
    if (sa2ios_install_status(game, sizeof game, overlay, sizeof overlay, w, sizeof w) != 1) {
        std::snprintf(why, why_n, "the game is not installed: %s", w);
        return -1;
    }
    if (sa2_ios_game_started()) {
        std::snprintf(why, why_n, "the game has run in this app: quit the app, open it again, and import first");
        return -1;
    }
    // The overlay's save folder, spelled as the game folder spells it when it has one.
    std::string save_dir = std::string(overlay) + "/" + sa2s::kSaveDir;
    const std::vector<sa2s::SeenFile> seen = sa2s::seen_files(game, overlay, sa2s::kSaveDir, false);
    if (!sa2p::make_dirs(save_dir)) {
        std::snprintf(why, why_n, "cannot create %s", save_dir.c_str());
        return -1;
    }
    std::vector<std::string> names;
    if (!sa2p::list_dir(src, names)) {
        std::snprintf(why, why_n, "cannot read %s", src);
        return -1;
    }
    int copied = 0;
    for (const std::string& name : names) {
        const std::string from = std::string(src) + "/" + name;
        if (!exists_file(from) || name[0] == '.') continue;
        std::string to_name = name;
        for (const sa2s::SeenFile& f : seen)
            if (sa2_install_fold(f.name) == sa2_install_fold(name)) to_name = f.name;
        // A file of another spelling in the overlay goes first, so the game sees one.
        std::vector<std::string> have;
        sa2p::list_dir(save_dir, have);
        for (const std::string& h : have)
            if (sa2_install_fold(h) == sa2_install_fold(name) && h != to_name) std::remove((save_dir + "/" + h).c_str());
        std::error_code ec;
        std::filesystem::copy_file(from, save_dir + "/" + to_name, std::filesystem::copy_options::overwrite_existing, ec);
        if (ec) {
            std::snprintf(why, why_n, "%s: %s", name.c_str(), ec.message().c_str());
            return -1;
        }
        copied++;
    }
    return copied;
}
