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
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

int main(void) {
    char *argv[] = {
        "/usr/local/bin/tailscaled",
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

    int status;
    if (waitpid(pid, &status, 0) < 0) return 1;

    if (WIFSIGNALED(status)) {
        fprintf(stderr, "tsboot: tailscaled killed by signal %d\n", WTERMSIG(status));
        return 1;
    }
    fprintf(stderr, "tsboot: tailscaled exited %d\n", WEXITSTATUS(status));
    return WEXITSTATUS(status);
}
