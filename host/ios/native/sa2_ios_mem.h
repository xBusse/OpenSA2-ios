// sa2_ios_mem.h: the app's memory, as iOS counts it against the app's limit, and where it went.
//
// iOS ends an app that passes its per-process limit (a JetsamEvent, "per-process-limit"), often
// with no crash report and nothing in the app's own log. The session (sa2_ios_session.mm) writes
// a line of mem_sample() every second to <session>/mem.tsv, so the climb is on record, split by
// kind: the footprint iOS counts, the part of it Metal holds (the graphics ledger: textures,
// buffers, the drawable), what malloc has handed out, and what iOS says is left.
//
// mem_watch_start() also has libmalloc tell it of every allocation (its malloc_logger hook, found
// with dlsym; nothing when it is not there) and keeps those of kBigBytes or more with their call
// stack, in a fixed ring the hook fills without allocating. mem_big_drain() names them (dladdr), for
// <session>/mem-big.txt: which code asked for the memory.
#pragma once

#include <string>
#include <vector>

namespace sa2ios {

constexpr size_t kBigBytes = size_t(32) << 20;

struct MemSample {
    double footprint_mib = -1;   // phys_footprint: what the limit is measured against
    double graphics_mib = -1;    // ledger_tag_graphics_footprint: Metal's part of it
    double malloc_mib = -1;      // malloc_zone_statistics: bytes in use in every zone
    double available_mib = -1;   // os_proc_available_memory
};

MemSample mem_sample();
void mem_watch_start();
std::vector<std::string> mem_big_drain();
// Every VM region of the app, its dirty and swapped-out pages summed by the region's tag (malloc's
// kinds, stacks, Metal's IOAccelerator, mapped files, untagged mmap...), with the largest regions:
// what the footprint is made of. A few milliseconds; the session runs it when the footprint jumps.
std::string mem_regions();

}  // namespace sa2ios
