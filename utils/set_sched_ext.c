#include <stdio.h>
#include <stdlib.h>
#include <sched.h>

#ifndef SCHED_EXT
#define SCHED_EXT 7
#endif

int main(int argc, char *argv[]) {
    if (argc < 2) {
        fprintf(stderr, "usage: set_sched_ext <pid> [pid ...]\n");
        return 1;
    }

    struct sched_param param = { .sched_priority = 0 };
    int ret = 0;

    for (int i = 1; i < argc; i++) {
        pid_t pid = (pid_t)atoi(argv[i]);
        if (sched_setscheduler(pid, SCHED_EXT, &param) != 0) {
            perror("sched_setscheduler");
            fprintf(stderr, "  pid: %d\n", pid);
            ret = 1;
        }
    }

    return ret;
}
