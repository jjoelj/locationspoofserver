// Supervises tailscaled on behalf of launchd.
//
// launchd cannot spawn tailscaled directly: the jailbreak's pspawn_payload
// hooks posix_spawn inside launchd and injects itself into every job it
// starts, which SIGKILLs the Go runtime a few seconds in (no crash report, no
// jetsam event -- just signal 9). The hook lives in launchd, so anything we
// spawn ourselves is untouched, which is why tailscaled runs fine from a shell.
//
// So launchd starts this instead: a signed C binary small enough that being
// injected does not matter, which spawns tailscaled itself and waits. Exiting
// with the child's status lets the job's KeepAlive do the restarting.

#include <spawn.h>
#include <stdio.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

// tailscaled shares our stderr (/var/log/tailscaled.log), which launchd only
// ever appends to; empty it past 1MB. lseek covers a non-O_APPEND open.
static void trim_log(void) {
    struct stat st;
    if (fstat(STDERR_FILENO, &st) == 0 && st.st_size > (1 << 20)) {
        ftruncate(STDERR_FILENO, 0);
        lseek(STDERR_FILENO, 0, SEEK_SET);
    }
}

int main(void) {
    trim_log();
    char *argv[] = {
        THEOS_PACKAGE_INSTALL_PREFIX "/usr/local/bin/tailscaled",
        "--tun=userspace-networking",
        "--statedir=/var/lib/tailscale",
        "--socket=/var/run/lss-tailscaled.socket",
        NULL,
    };

    pid_t pid;
    int err = posix_spawn(&pid, argv[0], NULL, NULL, argv, environ);
    if (err != 0) {
        fprintf(stderr, "tsboot: posix_spawn failed: %d\n", err);
        return 1;
    }
    fprintf(stderr, "tsboot: tailscaled started as pid %d\n", pid);
    fflush(stderr);

    // Poll instead of blocking so the log can be trimmed meanwhile; 5s is the
    // most a dead tailscaled waits before KeepAlive restarts it.
    int status;
    for (int i = 1;; i++) {
        pid_t r = waitpid(pid, &status, WNOHANG);
        if (r == pid) break;
        if (r < 0) return 1;
        if (i % 12 == 0) trim_log();
        sleep(5);
    }

    if (WIFSIGNALED(status)) {
        fprintf(stderr, "tsboot: tailscaled killed by signal %d\n", WTERMSIG(status));
        return 1;
    }
    fprintf(stderr, "tsboot: tailscaled exited %d\n", WEXITSTATUS(status));
    return WEXITSTATUS(status);
}
