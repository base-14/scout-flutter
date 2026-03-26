/**
 * Native signal handler for Android NDK crashes.
 *
 * Installs handlers for SIGSEGV, SIGABRT, SIGBUS, SIGFPE, SIGILL.
 * On crash, writes a JSON report with:
 *   - Signal info and fault address
 *   - Register dump from the crashed context
 *   - Stack trace via frame pointer walk from the crashed thread
 *   - /proc/self/maps for offline symbolication
 *
 * License: Part of scout_flutter (MIT).
 * Uses only async-signal-safe functions (no malloc, no stdio).
 */

#include <jni.h>
#include <signal.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <time.h>
#include <sys/types.h>
#include <sys/ucontext.h>
#include <sys/prctl.h>
#include <dlfcn.h>

/* Max path length for crash directory */
#define MAX_PATH 512

/* Max stack frames to capture */
#define MAX_FRAMES 64

/* Crash directory path, set from Java */
static char g_crash_dir[MAX_PATH];

/* Previous signal handlers to chain to */
static struct sigaction g_old_handlers[32];

/* Signals we handle */
static const int g_signals[] = { SIGSEGV, SIGABRT, SIGBUS, SIGFPE, SIGILL };
static const int g_signal_count = 5;

/* Signal-safe integer to string */
static int int_to_str(char *buf, int buflen, long val) {
    if (buflen < 2) return 0;
    if (val == 0) {
        buf[0] = '0';
        buf[1] = '\0';
        return 1;
    }
    int neg = 0;
    if (val < 0) {
        neg = 1;
        val = -val;
    }
    char tmp[20];
    int i = 0;
    while (val > 0 && i < 19) {
        tmp[i++] = '0' + (val % 10);
        val /= 10;
    }
    int pos = 0;
    if (neg && pos < buflen - 1) buf[pos++] = '-';
    while (i > 0 && pos < buflen - 1) {
        buf[pos++] = tmp[--i];
    }
    buf[pos] = '\0';
    return pos;
}

/* Signal-safe hex conversion */
static int ulong_to_hex(char *buf, int buflen, unsigned long val) {
    if (buflen < 2) return 0;
    if (val == 0) {
        buf[0] = '0';
        buf[1] = '\0';
        return 1;
    }
    char tmp[16];
    int ti = 0;
    while (val > 0 && ti < 16) {
        int d = val & 0xF;
        tmp[ti++] = d < 10 ? '0' + d : 'a' + d - 10;
        val >>= 4;
    }
    int pos = 0;
    while (ti > 0 && pos < buflen - 1) {
        buf[pos++] = tmp[--ti];
    }
    buf[pos] = '\0';
    return pos;
}

/* Get signal name */
static const char *signal_name(int sig) {
    switch (sig) {
        case SIGSEGV: return "SIGSEGV";
        case SIGABRT: return "SIGABRT";
        case SIGBUS:  return "SIGBUS";
        case SIGFPE:  return "SIGFPE";
        case SIGILL:  return "SIGILL";
        default:      return "UNKNOWN";
    }
}

/* Get signal code name */
static const char *signal_code_name(int sig, int code) {
    /* Generic codes (apply to all signals) */
    switch (code) {
        case SI_USER:    return "SI_USER";
        case SI_QUEUE:   return "SI_QUEUE";
        case SI_TKILL:   return "SI_TKILL";
        case SI_KERNEL:  return "SI_KERNEL";
    }
    /* Signal-specific codes */
    if (sig == SIGSEGV) {
        switch (code) {
            case SEGV_MAPERR: return "SEGV_MAPERR";
            case SEGV_ACCERR: return "SEGV_ACCERR";
        }
    } else if (sig == SIGBUS) {
        switch (code) {
            case BUS_ADRALN: return "BUS_ADRALN";
            case BUS_ADRERR: return "BUS_ADRERR";
            case BUS_OBJERR: return "BUS_OBJERR";
        }
    } else if (sig == SIGFPE) {
        switch (code) {
            case FPE_INTDIV: return "FPE_INTDIV";
            case FPE_INTOVF: return "FPE_INTOVF";
            case FPE_FLTDIV: return "FPE_FLTDIV";
            case FPE_FLTOVF: return "FPE_FLTOVF";
        }
    } else if (sig == SIGILL) {
        switch (code) {
            case ILL_ILLOPC: return "ILL_ILLOPC";
            case ILL_ILLOPN: return "ILL_ILLOPN";
            case ILL_PRVOPC: return "ILL_PRVOPC";
        }
    }
    return "UNKNOWN";
}

/* Signal-safe string append */
static int safe_append(char *buf, int pos, int buflen, const char *str) {
    while (*str && pos < buflen - 1) {
        buf[pos++] = *str++;
    }
    buf[pos] = '\0';
    return pos;
}

/* Append a hex value with label: "  label: 0xHEX" */
static int append_reg(char *buf, int pos, int buflen, const char *name, unsigned long val) {
    pos = safe_append(buf, pos, buflen, name);
    pos = safe_append(buf, pos, buflen, ": 0x");
    char hex[20];
    ulong_to_hex(hex, sizeof(hex), val);
    pos = safe_append(buf, pos, buflen, hex);
    return pos;
}

/* Append a single stack frame with dladdr resolution */
static int append_frame(char *buf, int pos, int buflen, int frame_num, uintptr_t pc) {
    pos = safe_append(buf, pos, buflen, "#");
    char num[8];
    int_to_str(num, sizeof(num), (long)frame_num);
    pos = safe_append(buf, pos, buflen, num);
    pos = safe_append(buf, pos, buflen, " pc 0x");

    char pchex[20];
    ulong_to_hex(pchex, sizeof(pchex), (unsigned long)pc);
    pos = safe_append(buf, pos, buflen, pchex);

    Dl_info dl_info;
    if (dladdr((void *)pc, &dl_info)) {
        if (dl_info.dli_fname) {
            pos = safe_append(buf, pos, buflen, " ");
            const char *fname = dl_info.dli_fname;
            const char *slash = fname;
            while (*fname) {
                if (*fname == '/') slash = fname + 1;
                fname++;
            }
            pos = safe_append(buf, pos, buflen, slash);
        }
        if (dl_info.dli_sname) {
            pos = safe_append(buf, pos, buflen, " (");
            pos = safe_append(buf, pos, buflen, dl_info.dli_sname);
            pos = safe_append(buf, pos, buflen, "+0x");
            char off[20];
            ulong_to_hex(off, sizeof(off), (unsigned long)(pc - (uintptr_t)dl_info.dli_saddr));
            pos = safe_append(buf, pos, buflen, off);
            pos = safe_append(buf, pos, buflen, ")");
        } else if (dl_info.dli_fbase) {
            pos = safe_append(buf, pos, buflen, " (+0x");
            char off[20];
            ulong_to_hex(off, sizeof(off), (unsigned long)(pc - (uintptr_t)dl_info.dli_fbase));
            pos = safe_append(buf, pos, buflen, off);
            pos = safe_append(buf, pos, buflen, ")");
        }
    }

    pos = safe_append(buf, pos, buflen, "\\n");
    return pos;
}

/**
 * Check if a memory address is likely readable.
 * Uses write() to /dev/null as a signal-safe way to test readability.
 * Returns 1 if the address seems readable, 0 otherwise.
 */
static int is_readable(const void *addr, size_t len) {
    if (addr == NULL) return 0;
    /* Addresses below 4096 are almost certainly invalid (null page) */
    if ((uintptr_t)addr < 4096) return 0;
    /* Try to write from the address to /dev/null — if it faults, the kernel
     * returns -1 with EFAULT instead of killing us (we're already in a signal
     * handler on the alternate stack). */
    int fd = open("/dev/null", O_WRONLY);
    if (fd < 0) return 0;
    ssize_t ret = write(fd, addr, len);
    close(fd);
    return ret >= 0;
}

/**
 * Signal handler — uses async-signal-safe functions only.
 *
 * Extracts the crashed thread's registers from ucontext_t and walks
 * the frame pointer chain to get the actual crash stack trace.
 */
static void crash_signal_handler(int sig, siginfo_t *info, void *context) {
    ucontext_t *uc = (ucontext_t *)context;

    /* Extract registers from crashed context */
    uintptr_t crash_pc = 0;
    uintptr_t crash_lr = 0;
    uintptr_t crash_sp = 0;
    uintptr_t crash_fp = 0;

#if defined(__aarch64__)
    crash_pc = uc->uc_mcontext.pc;
    crash_sp = uc->uc_mcontext.sp;
    crash_fp = uc->uc_mcontext.regs[29]; /* x29 = FP */
    crash_lr = uc->uc_mcontext.regs[30]; /* x30 = LR */
#elif defined(__arm__)
    crash_pc = uc->uc_mcontext.arm_pc;
    crash_sp = uc->uc_mcontext.arm_sp;
    crash_fp = uc->uc_mcontext.arm_fp;
    crash_lr = uc->uc_mcontext.arm_lr;
#elif defined(__x86_64__)
    crash_pc = uc->uc_mcontext.gregs[REG_RIP];
    crash_sp = uc->uc_mcontext.gregs[REG_RSP];
    crash_fp = uc->uc_mcontext.gregs[REG_RBP];
    crash_lr = 0; /* x86 uses stack-based return */
#elif defined(__i386__)
    crash_pc = uc->uc_mcontext.gregs[REG_EIP];
    crash_sp = uc->uc_mcontext.gregs[REG_ESP];
    crash_fp = uc->uc_mcontext.gregs[REG_EBP];
    crash_lr = 0;
#else
    /* Unknown architecture — registers unavailable */
    (void)uc;
#endif

    /* Walk frame pointer chain from crashed context */
    uintptr_t frames[MAX_FRAMES];
    int frame_count = 0;

    /* Frame 0: the crash PC itself */
    if (crash_pc != 0) {
        frames[frame_count++] = crash_pc;
    }

    /* Frame 1: LR (return address at point of crash) */
    if (crash_lr != 0 && crash_lr != crash_pc) {
        frames[frame_count++] = crash_lr;
    }

    /* Walk FP chain: on ARM64, [FP+0] = prev FP, [FP+8] = return addr */
    uintptr_t fp = crash_fp;
    while (fp != 0 && frame_count < MAX_FRAMES) {
        /* Validate FP is readable before dereferencing */
        if (!is_readable((void *)fp, sizeof(uintptr_t) * 2)) break;

        uintptr_t *frame = (uintptr_t *)fp;
        uintptr_t prev_fp = frame[0];
        uintptr_t ret_addr = frame[1];

        if (ret_addr == 0) break;
        frames[frame_count++] = ret_addr;

        /* Ensure we're walking up the stack (FP should increase) */
        if (prev_fp <= fp) break;
        fp = prev_fp;
    }

    /* Build file path: {crash_dir}/crash_{timestamp}.json */
    char path[MAX_PATH + 64];
    int pos = 0;
    pos = safe_append(path, pos, sizeof(path), g_crash_dir);
    pos = safe_append(path, pos, sizeof(path), "/crash_");

    char ts[20];
    int_to_str(ts, sizeof(ts), (long)time(NULL));
    pos = safe_append(path, pos, sizeof(path), ts);
    pos = safe_append(path, pos, sizeof(path), ".json");

    /* Get process/thread info (all async-signal-safe) */
    pid_t pid = getpid();
    pid_t tid = gettid();
    uid_t uid = getuid();
    char thread_name[16] = {0};
    prctl(PR_GET_NAME, (unsigned long)thread_name, 0, 0, 0);

    /* Read ABI at compile time */
#if defined(__aarch64__)
    const char *abi = "arm64";
#elif defined(__arm__)
    const char *abi = "arm";
#elif defined(__x86_64__)
    const char *abi = "x86_64";
#elif defined(__i386__)
    const char *abi = "x86";
#else
    const char *abi = "unknown";
#endif

    /* Read build fingerprint from /system/build.prop (signal-safe) */
    char fingerprint[256] = {0};
    {
        int prop_fd = open("/system/build.prop", O_RDONLY);
        if (prop_fd >= 0) {
            char prop_buf[4096];
            ssize_t prop_read = read(prop_fd, prop_buf, sizeof(prop_buf) - 1);
            close(prop_fd);
            if (prop_read > 0) {
                prop_buf[prop_read] = '\0';
                const char *needle = "ro.build.fingerprint=";
                char *found = strstr(prop_buf, needle);
                if (found) {
                    found += strlen(needle);
                    int fi = 0;
                    while (*found && *found != '\n' && fi < (int)sizeof(fingerprint) - 1) {
                        fingerprint[fi++] = *found++;
                    }
                    fingerprint[fi] = '\0';
                }
            }
        }
    }

    /* Read kernel version from /proc/version (signal-safe) */
    char kernel_version[128] = {0};
    {
        int ver_fd = open("/proc/version", O_RDONLY);
        if (ver_fd >= 0) {
            ssize_t ver_read = read(ver_fd, kernel_version, sizeof(kernel_version) - 1);
            close(ver_fd);
            if (ver_read > 0) {
                kernel_version[ver_read] = '\0';
                /* Trim at first newline */
                for (int k = 0; k < ver_read; k++) {
                    if (kernel_version[k] == '\n') {
                        kernel_version[k] = '\0';
                        break;
                    }
                }
            }
        }
    }

    /* Read process uptime from /proc/self/stat (signal-safe) */
    long uptime_secs = -1;
    {
        /* Get system uptime ticks from /proc/uptime */
        int up_fd = open("/proc/uptime", O_RDONLY);
        if (up_fd >= 0) {
            char up_buf[64];
            ssize_t up_read = read(up_fd, up_buf, sizeof(up_buf) - 1);
            close(up_fd);
            if (up_read > 0) {
                up_buf[up_read] = '\0';
                /* Parse system uptime (seconds before the dot) */
                long sys_uptime = 0;
                int ui = 0;
                while (up_buf[ui] >= '0' && up_buf[ui] <= '9') {
                    sys_uptime = sys_uptime * 10 + (up_buf[ui] - '0');
                    ui++;
                }

                /* Get process start time from /proc/self/stat field 22 */
                int stat_fd = open("/proc/self/stat", O_RDONLY);
                if (stat_fd >= 0) {
                    char stat_buf[512];
                    ssize_t stat_read = read(stat_fd, stat_buf, sizeof(stat_buf) - 1);
                    close(stat_fd);
                    if (stat_read > 0) {
                        stat_buf[stat_read] = '\0';
                        /* Skip past the comm field (in parentheses) */
                        char *cp = strrchr(stat_buf, ')');
                        if (cp) {
                            cp += 2; /* skip ") " */
                            /* Field 22 (starttime) is field 20 after the comm close
                             * Fields after comm: state(3), ppid(4), pgrp(5), session(6),
                             * tty_nr(7), tpgid(8), flags(9), minflt(10), cminflt(11),
                             * majflt(12), cmajflt(13), utime(14), stime(15), cutime(16),
                             * cstime(17), priority(18), nice(19), num_threads(20),
                             * itrealvalue(21), starttime(22) */
                            int field = 3;
                            while (*cp && field < 22) {
                                if (*cp == ' ') field++;
                                cp++;
                            }
                            long starttime = 0;
                            while (*cp >= '0' && *cp <= '9') {
                                starttime = starttime * 10 + (*cp - '0');
                                cp++;
                            }
                            /* starttime is in clock ticks, convert to seconds */
                            long clk_tck = sysconf(_SC_CLK_TCK);
                            if (clk_tck > 0) {
                                long proc_start_secs = starttime / clk_tck;
                                uptime_secs = sys_uptime - proc_start_secs;
                                if (uptime_secs < 0) uptime_secs = 0;
                            }
                        }
                    }
                }
            }
        }
    }

    /* Build JSON crash report */
    char buf[8192];
    int bpos = 0;
    bpos = safe_append(buf, bpos, sizeof(buf), "{\"crash_type\":\"native_signal\",\"crash_reason\":\"");
    bpos = safe_append(buf, bpos, sizeof(buf), signal_name(sig));
    bpos = safe_append(buf, bpos, sizeof(buf), "\",\"crash_signal_code\":\"");
    bpos = safe_append(buf, bpos, sizeof(buf), signal_code_name(sig, info ? info->si_code : 0));
    bpos = safe_append(buf, bpos, sizeof(buf), "\",\"crash_timestamp\":\"");
    bpos = safe_append(buf, bpos, sizeof(buf), ts);

    /* Thread name */
    bpos = safe_append(buf, bpos, sizeof(buf), "\",\"crash_thread_name\":\"");
    bpos = safe_append(buf, bpos, sizeof(buf), thread_name[0] ? thread_name : "unknown");

    /* PID, TID, UID */
    bpos = safe_append(buf, bpos, sizeof(buf), "\",\"crash_pid\":");
    char pidbuf[12];
    int_to_str(pidbuf, sizeof(pidbuf), (long)pid);
    bpos = safe_append(buf, bpos, sizeof(buf), pidbuf);
    bpos = safe_append(buf, bpos, sizeof(buf), ",\"crash_tid\":");
    char tidbuf[12];
    int_to_str(tidbuf, sizeof(tidbuf), (long)tid);
    bpos = safe_append(buf, bpos, sizeof(buf), tidbuf);
    bpos = safe_append(buf, bpos, sizeof(buf), ",\"crash_uid\":");
    char uidbuf[12];
    int_to_str(uidbuf, sizeof(uidbuf), (long)uid);
    bpos = safe_append(buf, bpos, sizeof(buf), uidbuf);

    /* ABI */
    bpos = safe_append(buf, bpos, sizeof(buf), ",\"crash_abi\":\"");
    bpos = safe_append(buf, bpos, sizeof(buf), abi);
    bpos = safe_append(buf, bpos, sizeof(buf), "\"");

    /* Build fingerprint */
    if (fingerprint[0]) {
        bpos = safe_append(buf, bpos, sizeof(buf), ",\"crash_build_fingerprint\":\"");
        bpos = safe_append(buf, bpos, sizeof(buf), fingerprint);
        bpos = safe_append(buf, bpos, sizeof(buf), "\"");
    }

    /* Kernel version */
    if (kernel_version[0]) {
        bpos = safe_append(buf, bpos, sizeof(buf), ",\"crash_kernel\":\"");
        /* Escape quotes in kernel version string */
        for (int k = 0; kernel_version[k] && bpos < (int)sizeof(buf) - 8; k++) {
            if (kernel_version[k] == '"') {
                bpos = safe_append(buf, bpos, sizeof(buf), "\\\"");
            } else if (bpos < (int)sizeof(buf) - 1) {
                buf[bpos++] = kernel_version[k];
                buf[bpos] = '\0';
            }
        }
        bpos = safe_append(buf, bpos, sizeof(buf), "\"");
    }

    /* Process uptime */
    if (uptime_secs >= 0) {
        bpos = safe_append(buf, bpos, sizeof(buf), ",\"crash_process_uptime_secs\":");
        char uptimebuf[12];
        int_to_str(uptimebuf, sizeof(uptimebuf), uptime_secs);
        bpos = safe_append(buf, bpos, sizeof(buf), uptimebuf);
    }

    /* Register dump */
    bpos = safe_append(buf, bpos, sizeof(buf), ",\"crash_registers\":\"");
    if (crash_pc == 0 && crash_fp == 0) {
        bpos = safe_append(buf, bpos, sizeof(buf), "unavailable (unsupported architecture)");
    } else {
        bpos = append_reg(buf, bpos, sizeof(buf), "pc", crash_pc);
        bpos = safe_append(buf, bpos, sizeof(buf), " ");
        bpos = append_reg(buf, bpos, sizeof(buf), "lr", crash_lr);
        bpos = safe_append(buf, bpos, sizeof(buf), " ");
        bpos = append_reg(buf, bpos, sizeof(buf), "sp", crash_sp);
        bpos = safe_append(buf, bpos, sizeof(buf), " ");
        bpos = append_reg(buf, bpos, sizeof(buf), "fp", crash_fp);
    }

#if defined(__aarch64__)
    /* Include all general-purpose registers for ARM64 */
    {
        const char *reg_names[] = {
            " x0", " x1", " x2", " x3", " x4", " x5", " x6", " x7",
            " x8", " x9", " x10", " x11", " x12", " x13", " x14", " x15",
            " x16", " x17", " x18", " x19", " x20", " x21", " x22", " x23",
            " x24", " x25", " x26", " x27", " x28"
        };
        for (int r = 0; r < 29 && bpos < (int)sizeof(buf) - 64; r++) {
            bpos = append_reg(buf, bpos, sizeof(buf), reg_names[r], uc->uc_mcontext.regs[r]);
        }
    }
#endif
    bpos = safe_append(buf, bpos, sizeof(buf), "\"");

    /* Stack trace from crashed context */
    bpos = safe_append(buf, bpos, sizeof(buf), ",\"crash_stack_trace\":\"");

    /* Signal info line */
    bpos = safe_append(buf, bpos, sizeof(buf), "signal ");
    char signum[8];
    int_to_str(signum, sizeof(signum), (long)sig);
    bpos = safe_append(buf, bpos, sizeof(buf), signum);

    if (info) {
        bpos = safe_append(buf, bpos, sizeof(buf), " at addr 0x");
        char hex[20];
        ulong_to_hex(hex, sizeof(hex), (unsigned long)info->si_addr);
        bpos = safe_append(buf, bpos, sizeof(buf), hex);
    }
    bpos = safe_append(buf, bpos, sizeof(buf), "\\n");

    /* Stack frames from FP walk */
    for (int i = 0; i < frame_count && bpos < (int)sizeof(buf) - 256; i++) {
        bpos = append_frame(buf, bpos, sizeof(buf), i, frames[i]);
    }

    bpos = safe_append(buf, bpos, sizeof(buf), "\"");

    /* Read /proc/self/maps for offline symbolication */
    bpos = safe_append(buf, bpos, sizeof(buf), ",\"crash_memory_map\":\"");
    {
        int maps_fd = open("/proc/self/maps", O_RDONLY);
        if (maps_fd >= 0) {
            /* Read maps into remaining buffer space (leave room for closing JSON) */
            int maps_space = (int)sizeof(buf) - bpos - 16;
            if (maps_space > 0) {
                char maps_buf[4096];
                ssize_t maps_read = read(maps_fd, maps_buf, sizeof(maps_buf) - 1);
                if (maps_read > 0) {
                    maps_buf[maps_read] = '\0';
                    /* Escape for JSON: replace newlines and backslashes */
                    for (int m = 0; m < maps_read && bpos < (int)sizeof(buf) - 16; m++) {
                        if (maps_buf[m] == '\n') {
                            bpos = safe_append(buf, bpos, sizeof(buf), "\\n");
                        } else if (maps_buf[m] == '\\') {
                            bpos = safe_append(buf, bpos, sizeof(buf), "\\\\");
                        } else if (maps_buf[m] == '"') {
                            bpos = safe_append(buf, bpos, sizeof(buf), "\\\"");
                        } else if (bpos < (int)sizeof(buf) - 1) {
                            buf[bpos++] = maps_buf[m];
                            buf[bpos] = '\0';
                        }
                    }
                }
            }
            close(maps_fd);
        }
    }
    bpos = safe_append(buf, bpos, sizeof(buf), "\"}");

    /* Write to file */
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd >= 0) {
        ssize_t dummy = write(fd, buf, bpos);
        (void)dummy;
        close(fd);
    }

    /* Re-raise with the original handler */
    if (sig >= 0 && sig < 32) {
        sigaction(sig, &g_old_handlers[sig], NULL);
    }
    raise(sig);
}

JNIEXPORT void JNICALL
Java_com_base14_scout_1flutter_CrashReporter_nativeInstallSignalHandler(
    JNIEnv *env, jclass clazz, jstring crashDirPath
) {
    const char *path = (*env)->GetStringUTFChars(env, crashDirPath, NULL);
    if (!path) return;

    /* Copy path to global buffer */
    int len = strlen(path);
    if (len >= MAX_PATH) len = MAX_PATH - 1;
    memcpy(g_crash_dir, path, len);
    g_crash_dir[len] = '\0';

    (*env)->ReleaseStringUTFChars(env, crashDirPath, path);

    /* Install signal handlers */
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sigemptyset(&sa.sa_mask);
    sa.sa_sigaction = crash_signal_handler;
    sa.sa_flags = SA_SIGINFO | SA_ONSTACK;

    for (int i = 0; i < g_signal_count; i++) {
        sigaction(g_signals[i], &sa, &g_old_handlers[g_signals[i]]);
    }
}
