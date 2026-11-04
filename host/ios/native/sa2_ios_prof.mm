// sa2_ios_prof.mm: the in-app sampler (sa2_ios_prof.h).
#include "sa2_ios_prof.h"

#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach/mach.h>
#include <mach/thread_info.h>
#include <mach/vm_param.h>
#include <pthread.h>
#include <time.h>
#include <unistd.h>

#include <algorithm>
#include <cinttypes>
#include <cstdio>
#include <cstring>
#include <map>
#include <unordered_map>
#include <vector>

namespace sa2ios {
namespace {

constexpr int kMaxThreads = 256;
constexpr int kMaxDepth = 20;

double now_s() {
    timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return double(ts.tv_sec) + double(ts.tv_nsec) / 1e9;
}

// A user address with any pointer-authentication bits (the system's arm64e code signs its return
// addresses) cleared: the smallest all-ones mask that covers the user address space.
uint64_t strip(uint64_t a) {
    uint64_t mask = 1;
    while (mask < uint64_t(MACH_VM_MAX_ADDRESS)) mask = (mask << 1) | 1;
    return a & mask;
}

struct Raw {                  // one sample, filled while its thread is suspended: no allocation
    uint64_t tid;
    bool running;
    int depth;
    uint64_t pc[kMaxDepth];
};

struct Frame {
    std::string text;         // image!symbol+0x.. [unslid 0x..]
    std::string fn;           // image!symbol (the key)
    bool app;                 // in the app's own executable
};

const mach_header* app_header() {
    static const mach_header* h = _dyld_get_image_header(0);
    return h;
}

intptr_t slide_of(const void* base) {
    for (uint32_t i = 0, n = _dyld_image_count(); i < n; i++)
        if (_dyld_get_image_header(i) == base) return _dyld_get_image_vmaddr_slide(i);
    return 0;
}

Frame describe(uint64_t pc, std::unordered_map<uint64_t, Frame>& cache) {
    auto it = cache.find(pc);
    if (it != cache.end()) return it->second;
    Frame f;
    Dl_info info{};
    char buf[512];
    if (dladdr(reinterpret_cast<void*>(pc), &info) && info.dli_fbase) {
        const char* img = info.dli_fname ? std::strrchr(info.dli_fname, '/') : nullptr;
        img = img ? img + 1 : (info.dli_fname ? info.dli_fname : "?");
        f.app = info.dli_fbase == app_header();
        const uint64_t unslid = pc - uint64_t(slide_of(info.dli_fbase));
        if (info.dli_sname) {
            const uint64_t off = pc - uint64_t(reinterpret_cast<uintptr_t>(info.dli_saddr));
            f.fn = std::string(img) + "!" + info.dli_sname;
            std::snprintf(buf, sizeof buf, "%s+0x%" PRIx64 " [0x%" PRIx64 "]", f.fn.c_str(), off, unslid);
        } else {
            std::snprintf(buf, sizeof buf, "%s!0x%" PRIx64, img, unslid);
            f.fn = buf;
        }
        f.text = buf;
    } else {
        std::snprintf(buf, sizeof buf, "?!0x%" PRIx64, pc);
        f.text = f.fn = buf;
        f.app = false;
    }
    cache.emplace(pc, f);
    return f;
}

uint64_t thread_id_of(thread_act_t t) {
    thread_identifier_info_data_t id{};
    mach_msg_type_number_t n = THREAD_IDENTIFIER_INFO_COUNT;
    if (thread_info(t, THREAD_IDENTIFIER_INFO, reinterpret_cast<thread_info_t>(&id), &n) != KERN_SUCCESS) return 0;
    return id.thread_id;
}

bool basic_of(thread_act_t t, thread_basic_info_data_t* b) {
    mach_msg_type_number_t n = THREAD_BASIC_INFO_COUNT;
    return thread_info(t, THREAD_BASIC_INFO, reinterpret_cast<thread_info_t>(b), &n) == KERN_SUCCESS;
}

double cpu_s(const thread_basic_info_data_t& b) {
    return double(b.user_time.seconds + b.system_time.seconds) +
           double(b.user_time.microseconds + b.system_time.microseconds) / 1e6;
}

std::string name_of(thread_act_t t) {
    char name[64] = {0};
    if (pthread_t p = pthread_from_mach_thread_np(t)) pthread_getname_np(p, name, sizeof name);
    return name[0] ? name : "(unnamed)";
}

bool is_game(const std::string& name) { return name == "sa2-game" || name.rfind("sa2-guest", 0) == 0; }

// One pass over the task's threads: CPU times by thread id, names, and (with `raw`) a sample of each.
int pass(thread_act_t self, std::vector<Raw>* raw, std::map<uint64_t, double>* cpu,
         std::map<uint64_t, std::string>* names) {
    thread_act_array_t list = nullptr;
    mach_msg_type_number_t n = 0;
    if (task_threads(mach_task_self(), &list, &n) != KERN_SUCCESS) return 0;
    int taken = 0;
    for (mach_msg_type_number_t i = 0; i < n; i++) {
        thread_act_t t = list[i];
        if (t != self) {
            const uint64_t tid = thread_id_of(t);
            thread_basic_info_data_t b{};
            const bool have = basic_of(t, &b);
            if (cpu && have) (*cpu)[tid] = cpu_s(b);
            if (names && !names->count(tid)) (*names)[tid] = name_of(t);
            if (raw && have && raw->size() < raw->capacity() && thread_suspend(t) == KERN_SUCCESS) {
                Raw& r = raw->emplace_back();     // capacity reserved: no allocation here
                r.tid = tid;
                r.running = b.run_state == TH_STATE_RUNNING;
                r.depth = 0;
                arm_thread_state64_t st{};
                mach_msg_type_number_t cnt = ARM_THREAD_STATE64_COUNT;
                if (thread_get_state(t, ARM_THREAD_STATE64, reinterpret_cast<thread_state_t>(&st), &cnt) ==
                    KERN_SUCCESS) {
                    r.pc[r.depth++] = strip(arm_thread_state64_get_pc(st));
                    const uint64_t lr = strip(arm_thread_state64_get_lr(st));
                    uint64_t fp = strip(arm_thread_state64_get_fp(st));
                    if (lr) r.pc[r.depth++] = lr;     // a leaf that has not pushed its frame yet
                    while (fp && !(fp & 15) && r.depth < kMaxDepth) {
                        uint64_t rec[2] = {0, 0};
                        vm_size_t got = 0;
                        if (vm_read_overwrite(mach_task_self(), fp, sizeof rec, reinterpret_cast<vm_address_t>(rec),
                                              &got) != KERN_SUCCESS || got != sizeof rec)
                            break;
                        const uint64_t next = strip(rec[0]), ret = strip(rec[1]);
                        if (!ret) break;
                        r.pc[r.depth++] = ret - 4;    // the call, not the instruction after it
                        if (next <= fp) break;
                        fp = next;
                    }
                }
                thread_resume(t);
                taken++;
            }
        }
        mach_port_deallocate(mach_task_self(), t);
    }
    vm_deallocate(mach_task_self(), reinterpret_cast<vm_address_t>(list), n * sizeof(thread_act_t));
    return taken;
}

template <class M>
std::vector<std::pair<std::string, int>> top(const M& m, size_t k) {
    std::vector<std::pair<std::string, int>> v(m.begin(), m.end());
    std::sort(v.begin(), v.end(), [](auto& a, auto& b) { return a.second > b.second; });
    if (v.size() > k) v.resize(k);
    return v;
}

}  // namespace

std::string prof_window(double seconds, int interval_ms, const std::string& out_path, const std::atomic<bool>& stop) {
    const thread_act_t self = mach_thread_self();
    std::map<uint64_t, double> cpu0, cpu1;
    std::map<uint64_t, std::string> names;
    std::vector<Raw> raw;
    raw.reserve(size_t(seconds * 1000.0 / std::max(interval_ms, 1)) * 24 + kMaxThreads);
    const double t0 = now_s();
    pass(self, nullptr, &cpu0, &names);
    int passes = 0;
    while (!stop.load() && now_s() - t0 < seconds && raw.size() + kMaxThreads < raw.capacity()) {
        pass(self, &raw, nullptr, &names);
        passes++;
        usleep(useconds_t(interval_ms) * 1000);
    }
    pass(self, nullptr, &cpu1, &names);
    const double wall = now_s() - t0;
    mach_port_deallocate(mach_task_self(), self);
    if (raw.empty() || wall <= 0) return "";

    // Per thread: CPU, samples, running samples; leaf and first-app-frame counts; for the game's
    // threads, where the waiting samples waited.
    struct Per {
        int samples = 0, running = 0;
        std::unordered_map<std::string, int> leaf, app_run, app_wait, wait_leaf;
    };
    std::map<uint64_t, Per> per;
    std::unordered_map<uint64_t, Frame> cache;
    std::unordered_map<std::string, std::string> example;   // fn -> one full text
    for (const Raw& r : raw) {
        Per& p = per[r.tid];
        p.samples++;
        if (r.depth == 0) continue;
        const Frame leaf = describe(r.pc[0], cache);
        example.emplace(leaf.fn, leaf.text);
        std::string first_app;
        for (int d = 0; d < r.depth; d++) {
            const Frame f = describe(r.pc[d], cache);
            if (f.app) {
                first_app = f.fn;
                example.emplace(f.fn, f.text);
                break;
            }
        }
        if (r.running) {
            p.running++;
            p.leaf[leaf.fn]++;
            if (!first_app.empty()) p.app_run[first_app]++;
        } else if (is_game(names[r.tid])) {
            p.wait_leaf[leaf.fn]++;
            if (!first_app.empty()) p.app_wait[first_app]++;
        }
    }

    struct Row {
        uint64_t tid;
        double cpu;
    };
    std::vector<Row> rows;
    for (auto& [tid, c1] : cpu1) {
        auto it = cpu0.find(tid);
        rows.push_back({tid, c1 - (it == cpu0.end() ? 0.0 : it->second)});
    }
    std::sort(rows.begin(), rows.end(), [](const Row& a, const Row& b) { return a.cpu > b.cpu; });

    std::string out;
    char line[1024];
    std::snprintf(line, sizeof line, "== window: %.1f s wall, %d passes, %zu samples\n", wall, passes, raw.size());
    out += line;
    out += "threads by CPU (CPU seconds per wall second; share of samples found running):\n";
    for (const Row& r : rows) {
        if (r.cpu < 0.005 && !is_game(names[r.tid])) continue;
        const Per& p = per[r.tid];
        std::snprintf(line, sizeof line, "  %-28s %5.2f  running %3d%% of %d\n", names[r.tid].c_str(), r.cpu / wall,
                      p.samples ? p.running * 100 / p.samples : 0, p.samples);
        out += line;
    }
    for (const Row& r : rows) {
        const std::string& nm = names[r.tid];
        const Per& p = per[r.tid];
        if (r.cpu / wall < 0.05 && !is_game(nm)) continue;
        out += "\n[" + nm + "]\n";
        auto list = [&](const char* title, const std::unordered_map<std::string, int>& m, int total) {
            if (m.empty() || total <= 0) return;
            out += std::string("  ") + title + ":\n";
            for (auto& [fn, k] : top(m, 25)) {
                std::snprintf(line, sizeof line, "    %5.1f%%  %s\n", 100.0 * k / total, example.count(fn) ? example[fn].c_str() : fn.c_str());
                out += line;
            }
        };
        list("running, leaf function", p.leaf, p.running);
        list("running, first frame in the app", p.app_run, p.running);
        list("waiting, leaf function", p.wait_leaf, p.samples - p.running);
        list("waiting, first frame in the app", p.app_wait, p.samples - p.running);
    }
    out += "\n";
    if (FILE* f = std::fopen(out_path.c_str(), "a")) {
        std::fwrite(out.data(), 1, out.size(), f);
        std::fclose(f);
    }

    // The report's line: the three busiest threads, and the game thread's top running function.
    std::string summary = "prof:";
    int shown = 0;
    for (const Row& r : rows) {
        if (shown == 3) break;
        std::snprintf(line, sizeof line, " %s %.0f%%", names[r.tid].c_str(), 100.0 * r.cpu / wall);
        summary += (shown ? "," : "") + std::string(line);
        shown++;
    }
    for (auto& [tid, p] : per) {
        if (names[tid] != "sa2-game") continue;
        auto t = top(p.leaf, 1);
        auto w = top(p.app_wait, 1);
        std::snprintf(line, sizeof line, "; sa2-game running %d%%%s%s%s%s", p.samples ? p.running * 100 / p.samples : 0,
                      t.empty() ? "" : ", mostly in ", t.empty() ? "" : t[0].first.c_str(),
                      w.empty() ? "" : ", waits in ", w.empty() ? "" : w[0].first.c_str());
        summary += line;
    }
    summary += " (prof.txt)";
    return summary;
}

}  // namespace sa2ios
