// sa2_poll_select.h: poll(2) for pipes and FIFOs, through select(2) on Darwin.
//
// Darwin builds poll() on kqueue, and on the iOS app's stream FIFO (host/ios: the game writes it,
// the relay reads it, one process) that route reported nothing while the game sat blocked in a
// write to a full FIFO: every wait ran to its timeout, so the relay took one pipe's worth of the
// stream each 100 ms and the game ran at one or two frames a second, its threads all idle (the first
// device sessions' sampler, host/ios/native/sa2_ios_prof.h). select() reaches a FIFO's and a pipe's
// readiness by the descriptor's own select routine instead, so the session's waits on its pipes go
// through it there. Elsewhere this is poll() itself.
//
// sa2_poll_fds(fds, n, timeout_ms) answers as poll() does for POLLIN and POLLOUT: the count of
// descriptors with an event, 0 on the timeout, -1 with errno on an error (EBADF for a closed one,
// which poll() would report as POLLNVAL). select() has no hang-up of its own: a descriptor at its
// end is readable, and the read that follows returns 0, which every caller here already takes as
// the end. Descriptors at or past FD_SETSIZE are refused (EINVAL); a session's are far below it.
#pragma once

#include <errno.h>
#include <poll.h>

#if defined(__APPLE__)
#include <sys/select.h>
#include <sys/time.h>

static inline int sa2_poll_fds(struct pollfd* fds, int n, int timeout_ms) {
    fd_set rd, wr;
    FD_ZERO(&rd);
    FD_ZERO(&wr);
    int top = -1;
    for (int i = 0; i < n; i++) {
        fds[i].revents = 0;
        if (fds[i].fd < 0) continue;
        if (fds[i].fd >= FD_SETSIZE) {
            errno = EINVAL;
            return -1;
        }
        if (fds[i].events & POLLIN) FD_SET(fds[i].fd, &rd);
        if (fds[i].events & POLLOUT) FD_SET(fds[i].fd, &wr);
        if (fds[i].fd > top) top = fds[i].fd;
    }
    struct timeval tv, *tvp = 0;
    if (timeout_ms >= 0) {
        tv.tv_sec = timeout_ms / 1000;
        tv.tv_usec = (timeout_ms % 1000) * 1000;
        tvp = &tv;
    }
    const int r = select(top + 1, &rd, &wr, 0, tvp);
    if (r <= 0) return r;
    int count = 0;
    for (int i = 0; i < n; i++) {
        if (fds[i].fd < 0) continue;
        if (FD_ISSET(fds[i].fd, &rd)) fds[i].revents |= POLLIN;
        if (FD_ISSET(fds[i].fd, &wr)) fds[i].revents |= POLLOUT;
        if (fds[i].revents) count++;
    }
    return count;
}
#else
static inline int sa2_poll_fds(struct pollfd* fds, int n, int timeout_ms) {
    return poll(fds, (nfds_t)n, timeout_ms);
}
#endif
