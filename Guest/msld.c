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

#define PORT 9999
#define BUF_SIZE 65536
#define TOKEN_SIZE 32
#define TOKEN_FILE "/etc/msld-token"
#define MAX_FORKS 64

static int                g_listen_fd  = -1;
static int                g_client_fd  = -1;
static volatile sig_atomic_t g_child_count = 0;
static char      g_display[64] = {0};
static unsigned char g_token[TOKEN_SIZE] = {0};
static int       g_token_bytes = 0;  /* 0 = not loaded, >0 = loaded with that many bytes */

static void handle_sigchld(int sig) {
    (void)sig;
    while (waitpid(-1, NULL, WNOHANG) > 0) {
        if (g_child_count > 0) g_child_count--;
    }
}

static void load_token(void) {
    if (g_token_bytes > 0) return;
    FILE *fp = fopen(TOKEN_FILE, "r");
    if (!fp) { g_token_bytes = -1; return; }
    size_t n = fread(g_token, 1, TOKEN_SIZE, fp);
    fclose(fp);
    g_token_bytes = (n > 0) ? (int)n : -1;
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
        if (n <= 0) return;
        buf = (const char *)buf + n;
        len -= n;
    }
}

static void serve_client(int client_fd) {
    g_client_fd = client_fd;
    probe_gateway();

    /* Auth: verify token before doing anything else. */
    if (!verify_token(client_fd)) {
        return;
    }

    struct timeval tv = {5, 0};
    fd_set rfds;
    FD_ZERO(&rfds);
    FD_SET(client_fd, &rfds);
    int sel = select(client_fd + 1, &rfds, NULL, NULL, &tv);
    if (sel <= 0) return;

    uint8_t mode;
    ssize_t n = read(client_fd, &mode, 1);
    if (n != 1) return;

    if (mode == 0x01) {
        struct winsize ws = { .ws_row = 24, .ws_col = 80, .ws_xpixel = 0, .ws_ypixel = 0 };
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
        int master_fd = -1;
        pid_t pid = forkpty(&master_fd, NULL, &tio, &ws);
        if (pid < 0) { if (master_fd >= 0) close(master_fd); return; }

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
            execl(shell, name, (char *)NULL);
            execl("/bin/sh", "-sh", (char *)NULL);
            _exit(127);
        }

        char buf[BUF_SIZE];
        while (1) {
            fd_set fds;
            FD_ZERO(&fds);
            int maxfd = 0;
            FD_SET(client_fd, &fds); maxfd = client_fd;
            FD_SET(master_fd, &fds); if (master_fd > maxfd) maxfd = master_fd;

            int ret = select(maxfd + 1, &fds, NULL, NULL, NULL);
            if (ret < 0) break;

            if (FD_ISSET(client_fd, &fds)) {
                ssize_t n = read(client_fd, buf, BUF_SIZE);
                if (n > 0) {
                    ssize_t pos = 0;
                    while (pos < n) {
                        ssize_t w = write(master_fd, buf + pos, n - pos);
                        if (w <= 0) goto shell_done;
                        pos += w;
                    }
                } else {
                    goto shell_done;
                }
            }

            if (FD_ISSET(master_fd, &fds)) {
                ssize_t n = read(master_fd, buf, BUF_SIZE);
                if (n > 0) {
                    ssize_t pos = 0;
                    while (pos < n) {
                        ssize_t w = write(client_fd, buf + pos, n - pos);
                        if (w <= 0) goto shell_done;
                        pos += w;
                    }
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
        int status;
        waitpid(pid, &status, 0);
        return;
    }

    if (mode != 0x00) return;

    uint32_t cmd_len;
    uint8_t len_buf[4];
    n = read(client_fd, len_buf, 4);
    if (n != 4) return;
    cmd_len = ntohl(*(uint32_t *)len_buf);
    if (cmd_len == 0 || cmd_len > BUF_SIZE - 1) return;

    char cmd[BUF_SIZE];
    size_t pos = 0;
    while (pos < cmd_len) {
        n = read(client_fd, cmd + pos, cmd_len - pos);
        if (n <= 0) return;
        pos += n;
    }
    cmd[cmd_len] = '\0';

    int out_pipe[2], err_pipe[2];
    if (pipe(out_pipe) < 0 || pipe(err_pipe) < 0) return;

    pid_t pid = fork();
    if (pid < 0) { close(out_pipe[0]); close(out_pipe[1]); close(err_pipe[0]); close(err_pipe[1]); return; }

    if (pid == 0) {
        close(out_pipe[0]); close(err_pipe[0]);
        dup2(out_pipe[1], STDOUT_FILENO);
        dup2(err_pipe[1], STDERR_FILENO);
        close(out_pipe[1]); close(err_pipe[1]);
        if (g_listen_fd > 2) close(g_listen_fd);
        if (client_fd > 2)   close(client_fd);
        if (g_display[0]) setenv("DISPLAY", g_display, 1);
        char sourced_cmd[BUF_SIZE];
        snprintf(sourced_cmd, sizeof(sourced_cmd), ". /root/.bashrc 2>/dev/null; exec %s", cmd);
        execl("/bin/sh", "sh", "-c", sourced_cmd, (char *)NULL);
        _exit(127);
    }

    close(out_pipe[1]); close(err_pipe[1]);

    char buf[BUF_SIZE];
    int out_fd = out_pipe[0], err_fd = err_pipe[0];
    int child_status = 0;
    int child_exited = 0;

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
            n = read(out_fd, buf, BUF_SIZE);
            if (n > 0) { xwrite(client_fd, buf, n); data = true; }
            else { close(out_fd); out_fd = -1; }
        }
        if (err_fd >= 0 && FD_ISSET(err_fd, &fds)) {
            n = read(err_fd, buf, BUF_SIZE);
            if (n > 0) { xwrite(client_fd, buf, n); data = true; }
            else { close(err_fd); err_fd = -1; }
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
    uint32_t exit_code = htonl(WIFEXITED(status) ? WEXITSTATUS(status) : (WIFSIGNALED(status) ? 128 + WTERMSIG(status) : 255));

    xwrite(client_fd, &exit_code, 4);
    shutdown(client_fd, SHUT_WR);
}

int main(void) {
    signal(SIGPIPE, SIG_IGN);
    signal(SIGCHLD, handle_sigchld);

    load_token();

    int fd = socket(AF_VSOCK, SOCK_STREAM, 0);
    g_listen_fd = fd;
    if (fd < 0) { fprintf(stderr, "msld: socket: %s\n", strerror(errno)); return 1; }

    struct sockaddr_vm addr;
    memset(&addr, 0, sizeof(addr));
    addr.svm_family = AF_VSOCK;
    addr.svm_cid = VMADDR_CID_ANY;
    addr.svm_port = PORT;

    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        fprintf(stderr, "msld: bind: %s\n", strerror(errno));
        close(fd); return 1;
    }

    if (listen(fd, 128) < 0) {
        fprintf(stderr, "msld: listen: %s\n", strerror(errno));
        close(fd); return 1;
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