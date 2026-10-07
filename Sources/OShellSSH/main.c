/* Old OpenSSH has no SSH_ASKPASS_REQUIRE=force. The supervised SSH child
 * has no controlling TTY, while its stdin/stdout still carry PTY traffic.
 * Darwin does not let a session leader detach via TIOCNOTTY, so use a new
 * child session and forward terminal/lifecycle signals from the wrapper. */
#include <sys/types.h>
#include <sys/wait.h>
#include <signal.h>
#include <stdlib.h>
#include <unistd.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>
static volatile sig_atomic_t ssh_pid = -1;
static void forward(int signal_number) {
    int saved_errno = errno;
    if (ssh_pid > 0) kill((pid_t)ssh_pid, signal_number);
    errno = saved_errno;
}
int main(int argc, char **argv) {
    const char *program = "/usr/bin/ssh";
    if (argc > 1 && strcmp(argv[1], "--scp") == 0) { program = "/usr/bin/scp"; ++argv; --argc; }
    const int forwarded[] = { SIGHUP, SIGTERM, SIGINT, SIGQUIT, SIGWINCH, SIGCONT };
    sigset_t blocked, previous;
    sigemptyset(&blocked);
    for (unsigned i=0; i<sizeof(forwarded)/sizeof(forwarded[0]); ++i) sigaddset(&blocked, forwarded[i]);
    sigprocmask(SIG_BLOCK, &blocked, &previous);
    signal(SIGCHLD, SIG_DFL);
    pid_t child = fork();
    if (child < 0) { perror("OShellSSH fork"); return 126; }
    if (child == 0) {
        if (setsid() < 0) _exit(126);
        for (unsigned i=0; i<sizeof(forwarded)/sizeof(forwarded[0]); ++i) signal(forwarded[i], SIG_DFL);
        sigprocmask(SIG_SETMASK, &previous, NULL);
        if (!getenv("DISPLAY") || !*getenv("DISPLAY")) setenv("DISPLAY", "oshell:0", 1);
        argv[0] = (char *)program;
        execv(argv[0], argv); perror("OShellSSH exec"); _exit(127);
    }
    ssh_pid = child;
    struct sigaction action = {0}; action.sa_handler = forward; sigemptyset(&action.sa_mask);
    for (unsigned i=0; i<sizeof(forwarded)/sizeof(forwarded[0]); ++i) sigaction(forwarded[i], &action, NULL);
    sigprocmask(SIG_SETMASK, &previous, NULL);
    /* Observe exit without reaping, then disable forwarding before the PID
     * can be recycled by the kernel. */
    siginfo_t info;
    while (waitid(P_PID, (id_t)child, &info, WEXITED | WNOWAIT) < 0) { if (errno != EINTR) return 126; }
    sigprocmask(SIG_BLOCK, &blocked, NULL); ssh_pid = -1;
    int status = 0;
    while (waitpid(child, &status, 0) < 0) { if (errno != EINTR) return 126; }
    return WIFEXITED(status) ? WEXITSTATUS(status) : WIFSIGNALED(status) ? 128 + WTERMSIG(status) : 126;
}
