// sa2_ios_console.mm: the app's standard output and error, kept (sa2_ios_console.h).
#include "sa2_ios_console.h"

#include <os/log.h>
#include <fcntl.h>
#include <pthread.h>
#include <unistd.h>

#include <atomic>
#include <cerrno>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <string>

namespace {

std::mutex g_mu;                 // the file and its path
std::string g_app_path, g_path;
FILE* g_file = nullptr;
std::atomic<bool> g_started{false};
int g_pipe_w = -1;
os_log_t g_log;

// Every byte written to the pipe before a switch reaches the old file: the switcher writes a marker
// line through the pipe and waits until the reader has passed it.
std::mutex g_flush_mu;
std::atomic<uint64_t> g_marks_sent{0}, g_marks_seen{0};
constexpr char kMark[] = "\x1e" "sa2-console-mark\n";

void open_locked(const std::string& path, bool truncate) {
    if (g_file) std::fclose(g_file);
    g_file = path.empty() ? nullptr : std::fopen(path.c_str(), truncate ? "w" : "a");
    if (g_file) setvbuf(g_file, nullptr, _IOLBF, 0);
    g_path = path;
}

void emit(const char* line, size_t n) {
    if (n >= sizeof kMark - 1 && std::memcmp(line, kMark, sizeof kMark - 1) == 0) {
        g_marks_seen.fetch_add(1);
        return;
    }
    {
        std::lock_guard<std::mutex> hold(g_mu);
        if (g_file) {
            std::fwrite(line, 1, n, g_file);
            std::fflush(g_file);
        }
    }
    // The unified log, without the newline.
    size_t len = n;
    while (len && (line[len - 1] == '\n' || line[len - 1] == '\r')) len--;
    os_log_with_type(g_log, OS_LOG_TYPE_DEFAULT, "%{public}.*s", int(len), line);
}

void* reader(void* arg) {
    pthread_setname_np("sa2-console");
    const int fd = int(intptr_t(arg));
    std::string pending;
    char buf[16384];
    for (;;) {
        const ssize_t got = read(fd, buf, sizeof buf);
        if (got <= 0) {
            if (got < 0 && errno == EINTR) continue;
            break;
        }
        pending.append(buf, size_t(got));
        size_t at = 0;
        for (;;) {
            const size_t nl = pending.find('\n', at);
            if (nl == std::string::npos) break;
            emit(pending.data() + at, nl + 1 - at);
            at = nl + 1;
        }
        pending.erase(0, at);
        // A line longer than the buffer is written as it comes.
        if (pending.size() > sizeof buf) {
            emit(pending.data(), pending.size());
            pending.clear();
        }
    }
    if (!pending.empty()) emit(pending.data(), pending.size());
    return nullptr;
}

}  // namespace

extern "C" void sa2ios_console_start(const char* path) {
    if (g_started.exchange(true)) {
        sa2ios_console_switch(path, 0);
        return;
    }
    g_log = os_log_create("com.sa2recomp.ios", "console");
    {
        std::lock_guard<std::mutex> hold(g_mu);
        g_app_path = path ? path : "";
        open_locked(g_app_path, false);
    }
    int p[2];
    if (pipe(p) != 0) return;
    fcntl(p[0], F_SETFD, FD_CLOEXEC);
    fflush(stdout);
    fflush(stderr);
    dup2(p[1], 1);
    dup2(p[1], 2);
    g_pipe_w = p[1];
    setvbuf(stdout, nullptr, _IOLBF, 0);
    setvbuf(stderr, nullptr, _IONBF, 0);
    pthread_t t;
    pthread_attr_t at;
    pthread_attr_init(&at);
    pthread_attr_setdetachstate(&at, PTHREAD_CREATE_DETACHED);
    pthread_create(&t, &at, reader, reinterpret_cast<void*>(intptr_t(p[0])));
    pthread_attr_destroy(&at);
}

extern "C" void sa2ios_console_switch(const char* path, int truncate) {
    std::lock_guard<std::mutex> one(g_flush_mu);
    if (g_started.load() && g_pipe_w >= 0) {
        // Everything written so far goes to the old file first.
        fflush(stdout);
        fflush(stderr);
        const uint64_t want = g_marks_sent.fetch_add(1) + 1;
        ssize_t ignored = write(g_pipe_w, kMark, sizeof kMark - 1);
        (void)ignored;
        for (int i = 0; i < 400 && g_marks_seen.load() < want; i++) usleep(5000);
    }
    std::lock_guard<std::mutex> hold(g_mu);
    open_locked(path ? std::string(path) : g_app_path, path && truncate);
}

extern "C" void sa2ios_console_path(char* out, size_t n) {
    std::lock_guard<std::mutex> hold(g_mu);
    std::snprintf(out, n, "%s", g_path.c_str());
}

extern "C" void sa2ios_console_line(const char* line) {
    std::fprintf(stderr, "%s\n", line);
}
