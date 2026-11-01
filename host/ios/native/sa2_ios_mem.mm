// sa2_ios_mem.mm: sa2_ios_mem.h.
#include "sa2_ios_mem.h"

#include <dlfcn.h>
#include <execinfo.h>
#include <mach/mach.h>
#include <malloc/malloc.h>
#include <os/proc.h>

#include <atomic>
#include <cinttypes>
#include <cstdio>
#include <cstring>

namespace sa2ios {
namespace {

// libmalloc's hook (libmalloc's malloc_logger: every allocation, free and realloc of every zone).
typedef void(malloc_logger_t)(uint32_t type, uintptr_t arg1, uintptr_t arg2, uintptr_t arg3, uintptr_t result,
                              uint32_t num_hot_frames_to_skip);
constexpr uint32_t kLogAllocate = 2, kLogDeallocate = 4;

constexpr int kRing = 128, kDepth = 24;
struct Big {
    std::atomic<uint32_t> state{0};   // 0 free, 1 being filled, 2 ready
    size_t bytes = 0;
    uintptr_t at = 0;
    int depth = 0;
    void* frames[kDepth] = {};
};
Big g_ring[kRing];
std::atomic<uint32_t> g_next{0}, g_read{0};
std::atomic<uint64_t> g_dropped{0};

void logger(uint32_t type, uintptr_t arg1, uintptr_t arg2, uintptr_t arg3, uintptr_t result, uint32_t) {
    // Nothing here allocates (backtrace walks frame pointers), so the hook cannot reenter itself.
    if (!(type & kLogAllocate)) return;
    // allocate: arg2 is the size; realloc (allocate and deallocate): arg3 is the new size
    const size_t bytes = (type & kLogDeallocate) ? size_t(arg3) : size_t(arg2);
    if (bytes < kBigBytes) return;
    const uint32_t slot = g_next.fetch_add(1) % kRing;
    Big& b = g_ring[slot];
    uint32_t expected = 0;
    if (b.state.compare_exchange_strong(expected, 1)) {
        b.bytes = bytes;
        b.at = result;
        b.depth = backtrace(b.frames, kDepth);   // walks frame pointers; allocates nothing
        b.state.store(2);
    } else {
        g_dropped.fetch_add(1);
    }
    (void)arg1;
}

std::string frame_text(void* pc) {
    Dl_info info{};
    char buf[512];
    if (dladdr(pc, &info) && info.dli_fname) {
        const char* img = std::strrchr(info.dli_fname, '/');
        img = img ? img + 1 : info.dli_fname;
        if (info.dli_sname)
            std::snprintf(buf, sizeof buf, "%s!%s+0x%" PRIxPTR, img, info.dli_sname,
                          uintptr_t(pc) - uintptr_t(info.dli_saddr));
        else
            std::snprintf(buf, sizeof buf, "%s!+0x%" PRIxPTR, img, uintptr_t(pc) - uintptr_t(info.dli_fbase));
    } else {
        std::snprintf(buf, sizeof buf, "?!%p", pc);
    }
    return buf;
}

}  // namespace

MemSample mem_sample() {
    MemSample s;
    task_vm_info_data_t vm{};
    mach_msg_type_number_t n = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, reinterpret_cast<task_info_t>(&vm), &n) == KERN_SUCCESS) {
        s.footprint_mib = double(vm.phys_footprint) / 1048576.0;
        // the graphics ledger is in the structure's later revisions; an older kernel's count stops short
        if (n >= TASK_VM_INFO_COUNT) s.graphics_mib = double(vm.ledger_tag_graphics_footprint) / 1048576.0;
    }
    malloc_statistics_t st{};
    malloc_zone_statistics(nullptr, &st);
    s.malloc_mib = double(st.size_in_use) / 1048576.0;
    s.available_mib = double(os_proc_available_memory()) / 1048576.0;
    return s;
}

void mem_watch_start() {
    static std::atomic<bool> once{false};
    if (once.exchange(true)) return;
    auto** hook = reinterpret_cast<malloc_logger_t**>(dlsym(RTLD_DEFAULT, "malloc_logger"));
    if (hook) *hook = &logger;
}

std::vector<std::string> mem_big_drain() {
    std::vector<std::string> out;
    const uint32_t upto = g_next.load();
    uint32_t from = g_read.load();
    if (upto - from > uint32_t(kRing)) from = upto - kRing;
    for (uint32_t i = from; i != upto; i++) {
        Big& b = g_ring[i % kRing];
        if (b.state.load() != 2) continue;
        char head[128];
        std::snprintf(head, sizeof head, "%.1f MiB at 0x%" PRIxPTR ":", double(b.bytes) / 1048576.0, b.at);
        std::string line = head;
        for (int d = 1; d < b.depth; d++) line += "\n    " + frame_text(b.frames[d]);
        out.push_back(line);
        b.state.store(0);
    }
    g_read.store(upto);
    if (const uint64_t lost = g_dropped.exchange(0))
        out.push_back(std::to_string(lost) + " more not kept (the ring was full)");
    return out;
}

}  // namespace sa2ios
