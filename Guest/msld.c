#include <sys/socket.h>
#include <linux/vm_sockets.h>
#include <unistd.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <signal.h>
#include <sys/wait.h>
#include <sys/types.h>
#include <errno.h>
#include <stdbool.h>
#include <arpa/inet.h>
#include <pty.h>
#include <termios.h>
#include <pwd.h>
#include <sys/time.h>
#include <sys/syscall.h>
#include <sys/utsname.h>
#include <fcntl.h>

/*
 * Trust boundary: This daemon runs inside the guest VM. Every connection
 * is authenticated with a 32-byte random token shared with the host
 * (~/.msl/token == /etc/msld-token). Once authenticated, the client is
 * trusted to execute arbitrary shell commands (mode 0x00) or spawn an
 * interactive shell (mode 0x01). There is no TLS or rate-limiting at
 * this layer — the token is the sole access control.
 */

#define PORT 9999
#define BUF_SIZE 65536
#define TOKEN_SIZE 32
#define TOKEN_FILE "/etc/msld-token"
#define MAX_FORKS 64

static int                g_listen_fd  = -1;
static volatile sig_atomic_t g_child_count = 0;
static char      g_display[64] = {0};
static unsigned char g_token[TOKEN_SIZE] = {0};
static int       g_token_bytes = 0;  /* 0 = not loaded, >0 = loaded with that many bytes */

static volatile sig_atomic_t g_cmd_pid = 0;
static volatile sig_atomic_t g_alarm_fired = 0;

static void handle_sigchld(int sig) {
    (void)sig;
    while (waitpid(-1, NULL, WNOHANG) > 0) {
        if (g_child_count > 0) g_child_count--;
    }
}

static void handle_sigalrm(int sig) {
    (void)sig;
    g_alarm_fired = 1;
    pid_t pid = g_cmd_pid;
    if (pid > 0) {
        kill(-pid, SIGKILL);
        kill(pid, SIGKILL);
    }
}

static void load_token(void) {
    if (g_token_bytes > 0) return;
    FILE *fp = fopen(TOKEN_FILE, "r");
    if (!fp) { g_token_bytes = -1; return; }
    size_t n = fread(g_token, 1, TOKEN_SIZE, fp);
    fclose(fp);
    g_token_bytes = (n == TOKEN_SIZE) ? TOKEN_SIZE : -1;
}

/* constant-time comparison to avoid timing side-channels on the auth token */
static int constant_time_cmp(const unsigned char *a, const unsigned char *b, size_t len) {
    int diff = 0;
    for (size_t i = 0; i < len; i++) diff |= (int)a[i] ^ (int)b[i];
    return diff;
}

static int verify_token(int client_fd) {
    load_token();
    /* No token file = no auth (backward compat) */
    if (g_token_bytes <= 0) return 1;

    /* Set a 10-second receive timeout on the socket for the token read */
    struct timeval tv = {10, 0};
    setsockopt(client_fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    unsigned char recv_token[TOKEN_SIZE];
    ssize_t total = 0;
    while (total < TOKEN_SIZE) {
        ssize_t n = read(client_fd, recv_token + total, TOKEN_SIZE - total);
        if (n <= 0) return 0;
        total += n;
    }
    return constant_time_cmp(g_token, recv_token, TOKEN_SIZE) == 0;
}

static void probe_gateway(void) {
    if (g_display[0]) return;
    FILE *fp = fopen("/proc/net/route", "r");
    if (!fp) return;
    char line[256];
    /* skip header */
    if (!fgets(line, sizeof(line), fp)) { fclose(fp); return; }
    while (fgets(line, sizeof(line), fp)) {
        char iface[64];
        unsigned int dest, gw, mask;
        if (sscanf(line, "%63s %x %x %*x %*d %*d %*d %x",
                   iface, &dest, &gw, &mask) >= 4) {
            if (dest == 0 && mask == 0 && gw != 0) {
                struct in_addr addr = { .s_addr = gw };
                snprintf(g_display, sizeof(g_display), "%s:0", inet_ntoa(addr));
                break;
            }
        }
    }
    fclose(fp);
}

static void xwrite(int fd, const void *buf, size_t len) {
    while (len > 0) {
        ssize_t n = write(fd, buf, len);
        if (n < 0) {
            if (errno == EINTR) {
                /* If the alarm fired while we were blocked writing,
                 * the command was already killed — stop forwarding
                 * output and let the caller clean up. */
                if (g_alarm_fired) return;
                continue;
            }
            return;
        }
        buf = (const char *)buf + n;
        len -= n;
    }
}

static ssize_t xread(int fd, void *buf, size_t count) {
    size_t remaining = count;
    while (remaining > 0) {
        ssize_t n = read(fd, (char *)buf + (count - remaining), remaining);
        if (n < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        if (n == 0) return -1;
        remaining -= n;
    }
    return count;
}

/* Read with EINTR retry — returns same as read() */
static ssize_t safe_read(int fd, void *buf, size_t count) {
    ssize_t n;
    do {
        n = read(fd, buf, count);
    } while (n < 0 && errno == EINTR);
    return n;
}

/* Write all bytes with EINTR retry, returns n written on success, -1 on error */
static ssize_t safe_write(int fd, const void *buf, size_t len) {
    size_t total = 0;
    while (total < len) {
        ssize_t n = write(fd, (const char *)buf + total, len - total);
        if (n < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        total += n;
    }
    return (ssize_t)total;
}

static void serve_client(int client_fd) {
    /* Auth: verify token before doing anything else. */
    if (!verify_token(client_fd)) {
        fprintf(stderr, "msld: token mismatch — rejecting connection\n");
        /* Send a non-zero byte so the host can distinguish "token
         * rejected" from a generic connection failure.  The host
         * polls after writeMslToken and expects a single byte;
         * anything other than 0x00 means rejection. */
        uint8_t nak = 0xFF;
        write(client_fd, &nak, 1);
        return;
    }
    /* Send ACK so the host knows the token was accepted before it
     * sends the mode byte / command.  Old hosts that don't poll for
     * this byte will just time out briefly and proceed. */
    uint8_t ack = 0x00;
    write(client_fd, &ack, 1);

    struct timeval tv = {5, 0};
    fd_set rfds;
    FD_ZERO(&rfds);
    FD_SET(client_fd, &rfds);
    int sel = select(client_fd + 1, &rfds, NULL, NULL, &tv);
    if (sel <= 0) return;

    uint16_t ws_row = 24, ws_col = 80;
    uint8_t mode;
    uint8_t first_byte;
    if (safe_read(client_fd, &first_byte, 1) != 1) return;

    if (first_byte == 0x02) {
        uint8_t ws_buf[4];
        if (xread(client_fd, ws_buf, 4) < 0) return;
        ws_row = (uint16_t)(ws_buf[0]) << 8 | ws_buf[1];
        ws_col = (uint16_t)(ws_buf[2]) << 8 | ws_buf[3];
        if (xread(client_fd, &mode, 1) < 0) return;
    } else {
        mode = first_byte;
    }

    if (mode == 0x01) {
        struct winsize ws = { .ws_row = ws_row, .ws_col = ws_col };
        struct termios tio;
        memset(&tio, 0, sizeof(tio));
        tio.c_iflag = ICRNL | IXON;
        tio.c_oflag = OPOST | ONLCR;
        tio.c_cflag = CS8 | CREAD;
        tio.c_lflag = ISIG | ICANON | ECHO | ECHOE | ECHOK | ECHOCTL | ECHOKE | IEXTEN;
        tio.c_cc[VINTR]  = 003;
        tio.c_cc[VQUIT]  = 034;
        tio.c_cc[VERASE] = 0177;
        tio.c_cc[VKILL]  = 025;
        tio.c_cc[VEOF]   = 004;
        tio.c_cc[VSTART] = 021;
        tio.c_cc[VSTOP]  = 023;
        tio.c_cc[VSUSP]  = 032;
        tio.c_cc[VMIN]   = 1;
        tio.c_cc[VTIME]  = 0;
        cfsetispeed(&tio, B38400);
        cfsetospeed(&tio, B38400);

        /* Block SIGCHLD around forkpty/waitpid to prevent the signal
         * handler from reaping the pty child before our explicit wait. */
        sigset_t old_sigchld, sigchld_block;
        sigemptyset(&sigchld_block);
        sigaddset(&sigchld_block, SIGCHLD);
        sigprocmask(SIG_BLOCK, &sigchld_block, &old_sigchld);

        int master_fd = -1;
        pid_t pid = forkpty(&master_fd, NULL, &tio, &ws);
        if (pid < 0) {
            sigprocmask(SIG_SETMASK, &old_sigchld, NULL);
            if (master_fd >= 0) close(master_fd);
            return;
        }

        if (pid == 0) {
            if (master_fd >= 0) close(master_fd);
            if (g_listen_fd > 2) close(g_listen_fd);
            if (client_fd > 2)  close(client_fd);
            setsid();
            if (g_display[0]) setenv("DISPLAY", g_display, 1);
            struct passwd *pw = getpwuid(getuid());
            const char *shell = (pw && pw->pw_shell && *pw->pw_shell) ? pw->pw_shell : "/bin/bash";
            if (access(shell, X_OK) != 0) shell = "/bin/sh";
            const char *base = strrchr(shell, '/');
            base = base ? base + 1 : shell;
            char name[64];
            snprintf(name, sizeof(name), "-%s", base);
            /* Restore SIGCHLD mask inherited from parent before exec.
             * Signal masks survive execve() — without this the shell
             * and all its children run with SIGCHLD blocked, breaking
             * job control and wait() notifications. */
            sigprocmask(SIG_SETMASK, &old_sigchld, NULL);
            execl(shell, name, (char *)NULL);
            execl("/bin/sh", "-sh", (char *)NULL);
            _exit(127);
        }

        char buf[BUF_SIZE];
        static unsigned char ws_pending[5];
        static int ws_pending_len = 0;
        while (1) {
            fd_set fds;
            FD_ZERO(&fds);
            int maxfd = 0;
            FD_SET(client_fd, &fds); maxfd = client_fd;
            FD_SET(master_fd, &fds); if (master_fd > maxfd) maxfd = master_fd;

            int ret = select(maxfd + 1, &fds, NULL, NULL, NULL);
            if (ret < 0) break;

            if (FD_ISSET(client_fd, &fds)) {
                ssize_t n;
                if (ws_pending_len > 0) {
                    memcpy(buf, ws_pending, ws_pending_len);
                    ssize_t more = safe_read(client_fd, buf + ws_pending_len, BUF_SIZE - ws_pending_len);
                    if (more <= 0) { ws_pending_len = 0; goto shell_done; }
                    n = ws_pending_len + more;
                    ws_pending_len = 0;
                } else {
                    n = safe_read(client_fd, buf, BUF_SIZE);
                }
                if (n > 0) {
                    ssize_t off = 0;
                    if (n >= 5 && buf[0] == 0x02) {
                        struct winsize ws2;
                        ws2.ws_row = (uint16_t)(buf[1]) << 8 | buf[2];
                        ws2.ws_col = (uint16_t)(buf[3]) << 8 | buf[4];
                        ws2.ws_xpixel = 0;
                        ws2.ws_ypixel = 0;
                        ioctl(master_fd, TIOCSWINSZ, &ws2);
                        off = 5;
                    } else if (buf[0] == 0x02 && n < 5 && n > 0) {
                        memcpy(ws_pending, buf, n);
                        ws_pending_len = n;
                        continue;
                    }
                    if (safe_write(master_fd, buf + off, n - off) < 0) goto shell_done;
                } else {
                    goto shell_done;
                }
            }

            if (FD_ISSET(master_fd, &fds)) {
                ssize_t n = safe_read(master_fd, buf, BUF_SIZE);
                if (n > 0) {
                    if (safe_write(client_fd, buf, n) < 0) goto shell_done;
                } else if (n == 0 || (n < 0 && errno == EIO)) {
                    goto shell_done;
                } else if (n < 0 && (errno == EINTR)) {
                    continue;
                } else {
                    goto shell_done;
                }
            }
        }

shell_done:
        if (master_fd >= 0) close(master_fd);
        /* Safety timeout: if the child doesn't exit within 120s, kill it */
        struct sigaction sa_alrm_shell, sa_alrm_shell_old;
        memset(&sa_alrm_shell, 0, sizeof(sa_alrm_shell));
        sa_alrm_shell.sa_handler = handle_sigalrm;
        sa_alrm_shell.sa_flags = SA_RESETHAND;
        sigaction(SIGALRM, &sa_alrm_shell, &sa_alrm_shell_old);
        g_cmd_pid = pid;
        alarm(120);
        int status;
        waitpid(pid, &status, 0);
        alarm(0);
        g_cmd_pid = 0;
        sigaction(SIGALRM, &sa_alrm_shell_old, NULL);
        sigprocmask(SIG_SETMASK, &old_sigchld, NULL);
        return;
    }

    if (mode != 0x00) return;

    uint32_t cmd_len;
    uint8_t len_buf[4];
    if (xread(client_fd, len_buf, 4) < 0) return;
    cmd_len = ntohl(*(uint32_t *)len_buf);
    if (cmd_len == 0 || cmd_len > BUF_SIZE - 1) return;

    char cmd[BUF_SIZE];
    if (xread(client_fd, cmd, cmd_len) < 0) return;
    cmd[cmd_len] = '\0';

    sigset_t old_sigchld, sigchld_block;
    sigemptyset(&sigchld_block);
    sigaddset(&sigchld_block, SIGCHLD);
    sigprocmask(SIG_BLOCK, &sigchld_block, &old_sigchld);

    int out_pipe[2], err_pipe[2];
    if (pipe(out_pipe) < 0 || pipe(err_pipe) < 0) { sigprocmask(SIG_SETMASK, &old_sigchld, NULL); return; }

    pid_t pid = fork();
    if (pid < 0) { close(out_pipe[0]); close(out_pipe[1]); close(err_pipe[0]); close(err_pipe[1]); sigprocmask(SIG_SETMASK, &old_sigchld, NULL); return; }

    /* 120s command ceiling — host budget is 30s, this is generous overkill */
    struct sigaction sa_alrm, sa_alrm_old;
    memset(&sa_alrm, 0, sizeof(sa_alrm));
    sa_alrm.sa_handler = handle_sigalrm;
    sa_alrm.sa_flags = SA_RESETHAND;
    sigaction(SIGALRM, &sa_alrm, &sa_alrm_old);
    g_cmd_pid = pid;
    alarm(120);

    if (pid == 0) {
        /* Child resets the alarm — it should not inherit the parent's timer */
        alarm(0);
        g_cmd_pid = 0;
        close(out_pipe[0]); close(err_pipe[0]);
        dup2(out_pipe[1], STDOUT_FILENO);
        dup2(err_pipe[1], STDERR_FILENO);
        close(out_pipe[1]); close(err_pipe[1]);
        if (g_listen_fd > 2) close(g_listen_fd);
        if (client_fd > 2)   close(client_fd);
        if (g_display[0]) setenv("DISPLAY", g_display, 1);
        /* Become a process group leader so kill(-pid, SIGKILL) works */
        setpgid(0, 0);
        /* Restore SIGCHLD mask — see shell fork comment above. */
        sigprocmask(SIG_SETMASK, &old_sigchld, NULL);
        execl("/bin/sh", "sh", "-c", cmd, (char *)NULL);
        _exit(127);
    }

    close(out_pipe[1]); close(err_pipe[1]);

    char buf[BUF_SIZE];
    int out_fd = out_pipe[0], err_fd = err_pipe[0];
    int child_status = 0;
    int child_exited = 0;
    unsigned long total_sent = 0;
    const unsigned long max_output = 10 * 1024 * 1024;

    while (1) {
        fd_set fds;
        FD_ZERO(&fds);
        int maxfd = 0;
        if (out_fd >= 0) { FD_SET(out_fd, &fds); if (out_fd > maxfd) maxfd = out_fd; }
        if (err_fd >= 0) { FD_SET(err_fd, &fds); if (err_fd > maxfd) maxfd = err_fd; }
        if (maxfd == 0) break;

        struct timeval tv = {1, 0};
        int ret = select(maxfd + 1, &fds, NULL, NULL, &tv);
        if (ret < 0) break;

        bool data = false;
        if (out_fd >= 0 && FD_ISSET(out_fd, &fds)) {
            ssize_t rn = safe_read(out_fd, buf, BUF_SIZE);
            if (rn > 0) {
                if (total_sent < max_output) {
                    size_t to_send = (total_sent + rn > max_output) ? max_output - total_sent : rn;
                    xwrite(client_fd, buf, to_send);
                    total_sent += to_send;
                    data = true;
                }
            } else { close(out_fd); out_fd = -1; }
        }
        if (err_fd >= 0 && FD_ISSET(err_fd, &fds)) {
            ssize_t rn = safe_read(err_fd, buf, BUF_SIZE);
            if (rn > 0) {
                if (total_sent < max_output) {
                    size_t to_send = (total_sent + rn > max_output) ? max_output - total_sent : rn;
                    xwrite(client_fd, buf, to_send);
                    total_sent += to_send;
                    data = true;
                }
            } else { close(err_fd); err_fd = -1; }
        }
        if (!data && ret == 0) {
            pid_t wpid = waitpid(pid, &child_status, WNOHANG);
            if (wpid == pid) { child_exited = 1; break; }
        }
    }

    if (out_fd >= 0) close(out_fd);
    if (err_fd >= 0) close(err_fd);

    int status;
    if (child_exited) {
        status = child_status;
    } else {
        waitpid(pid, &status, 0);
    }
    sigprocmask(SIG_SETMASK, &old_sigchld, NULL);
    alarm(0);
    g_cmd_pid = 0;
    sigaction(SIGALRM, &sa_alrm_old, NULL);
    uint32_t exit_code = htonl(WIFEXITED(status) ? WEXITSTATUS(status) : (WIFSIGNALED(status) ? 128 + WTERMSIG(status) : 255));

    xwrite(client_fd, &exit_code, 4);
    shutdown(client_fd, SHUT_WR);
}

int main(void) {
    signal(SIGPIPE, SIG_IGN);
    signal(SIGCHLD, handle_sigchld);

    load_token();
    probe_gateway();

    int fd = -1;
    struct sockaddr_vm addr;
    memset(&addr, 0, sizeof(addr));
    addr.svm_family = AF_VSOCK;
    addr.svm_cid = VMADDR_CID_ANY;
    addr.svm_port = PORT;

    /* Retry VSOCK socket/bind/listen in case kernel modules are still
     * being loaded.  Try to finit_module the VSOCK modules ourselves.
     * The disk image has pre-decompressed .ko files for this purpose
     * (zstd-compressed .ko.zst cannot be consumed by finit_module). */
    struct utsname uts;
    char modpath[320];
    const char *mods[] = {"vsock",
        "vmw_vsock_virtio_transport_common",
        "vmw_vsock_virtio_transport", NULL};
    int kver_ok = (uname(&uts) == 0);

    for (int retry = 0; ; retry++) {
        fd = socket(AF_VSOCK, SOCK_STREAM, 0);
        if (fd < 0) {
            if (errno == EAFNOSUPPORT || errno == EPROTONOSUPPORT) {
                /* Try loading the VSOCK kernel modules via finit_module.
                 * Order matters: vsock → transport_common → transport.
                 * The .ko files must be pre-decompressed in the image. */
                if (kver_ok) {
                    for (const char **m = mods; *m; m++) {
                        snprintf(modpath, sizeof(modpath),
                            "/usr/lib/modules/%s/kernel/net/vmw_vsock/%s.ko",
                            uts.release, *m);
                        int mfd = open(modpath, O_RDONLY);
                        if (mfd >= 0) {
                            syscall(SYS_finit_module, mfd, "", 0);
                            close(mfd);
                        }
                    }
                }
                if (retry > 600) {
                    fprintf(stderr, "msld: giving up on VSOCK after 5 min\n");
                    return 1;
                }
                usleep(500000);
                continue;
            }
            fprintf(stderr, "msld: socket: %s\n", strerror(errno));
            return 1;
        }

        if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
            int e = errno;
            close(fd);
            if (e == EADDRNOTAVAIL || e == EAGAIN) {
                usleep(500000);
                continue;
            }
            fprintf(stderr, "msld: bind: %s\n", strerror(e));
            return 1;
        }

        if (listen(fd, 128) < 0) {
            close(fd);
            usleep(500000);
            continue;
        }

        /* All three operations succeeded */
        g_listen_fd = fd;
        break;
    }

    sigset_t sigchld_set, sigchld_old;
    sigemptyset(&sigchld_set);
    sigaddset(&sigchld_set, SIGCHLD);

    while (1) {
        int client_fd = accept(fd, NULL, NULL);
        if (client_fd < 0) {
            if (errno == EINTR) continue;
            break;
        }

        /* Block SIGCHLD so the handler can't fire between load and store. */
        sigprocmask(SIG_BLOCK, &sigchld_set, &sigchld_old);
        int cur = g_child_count;
        if (cur >= MAX_FORKS) {
            sigprocmask(SIG_SETMASK, &sigchld_old, NULL);
            close(client_fd);
            continue;
        }

        pid_t pid = fork();
        if (pid < 0) {
            sigprocmask(SIG_SETMASK, &sigchld_old, NULL);
            close(client_fd);
            continue;
        }
        if (pid == 0) {
            /* Child — serve this one connection then exit */
            close(fd);
            serve_client(client_fd);
            close(client_fd);
            _exit(0);
        }
        /* Parent — track child while SIGCHLD is still blocked */
        g_child_count = cur + 1;
        sigprocmask(SIG_SETMASK, &sigchld_old, NULL);
        close(client_fd);
    }

    close(fd);
    return 0;
}
