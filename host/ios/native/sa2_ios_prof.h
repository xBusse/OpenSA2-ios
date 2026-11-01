// sa2_ios_prof.h: where the app's time goes, measured on the device with no tool attached.
//
// The session's perf thread (sa2_ios_session.mm) runs one window of it every 30 s instead of a plain
// sleep. A window samples every thread of the app every few milliseconds: it suspends the thread,
// reads its PC and walks its frame-pointer chain (Darwin's arm64 code keeps frame pointers), and
// resumes it, and it reads each thread's CPU time at the window's start and end. Nothing allocates
// while a thread is suspended (it may hold the allocator's lock).
//
// What a window writes, appended to <session>/prof.txt:
//   - each thread's CPU use over the window (seconds of CPU per second of wall) and how often a
//     sample found it running;
//   - for each thread that ran: the functions its samples were in (the leaf), and the first frame
//     in the app's own image (the code that called into a system library);
//   - for sa2-game and the guest threads, also where their waiting samples waited, by the first
//     app frame: what the game is blocked on when it is not computing.
// Every frame is "image!symbol+offset" (dladdr) with, for the app's image, its unslid address, so a
// symbol dladdr cannot name is found with atos and the build's dSYM.
// The report gets one line per window: the busiest threads and the game thread's top function.
#pragma once

#include <atomic>
#include <string>

namespace sa2ios {

// Samples for `seconds` (or until `stop`), every `interval_ms`; appends the window to `out_path`
// and returns the report's one-line summary ("" when nothing was sampled).
std::string prof_window(double seconds, int interval_ms, const std::string& out_path, const std::atomic<bool>& stop);

}  // namespace sa2ios
