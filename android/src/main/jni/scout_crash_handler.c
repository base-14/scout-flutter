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
#include <sys/utsname.h>
#include <sys/syscall.h>
#include <stdatomic.h>
#include <dlfcn.h>

/* Max path length for crash directory */
#define MAX_PATH 512

/* Max stack frames to capture */
#define MAX_FRAMES 64

/* Crash directory path, set from Java */
static char g_crash_dir[MAX_PATH];

/* Cached at install time (read once, written into every crash report). */
static long g_proc_start_boottime_secs = 0;
static long g_app_start_time_secs = 0;
static long g_system_boot_time_secs = 0;
static char g_kernel_release[128];
static char g_machine[96];
static char g_os_version[48];
static char g_os_build[96];
static char g_app_uuid[64];
static char g_bundle_id[128];
static char g_bundle_version[64];
static char g_app_version[64];
static char g_app_name[96];
static char g_process_name[96];
static char g_app_executable[128];
static char g_executable_path[256];
static char g_parent_proc_name[96];
static char g_time_zone[64];
static char g_build_type[16];
static char g_environment[32];
static char g_build_configuration[32];
static char g_device_app_hash[80];
static char g_idfv[80];
static int  g_parent_pid = -1;
static int  g_gid = -1;
static int  g_translated = 0;

static long g_storage_size_bytes = -1;
static long g_storage_free_bytes = -1;
static long g_memory_size_bytes = -1;

/* Updated at runtime via JNI. atomic_int is async-signal-safe. */
static atomic_int g_in_foreground = 0;
static atomic_int g_app_active = 0;
static atomic_int g_sessions_since_launch = 0;
static atomic_int g_sessions_since_last_crash = 0;
static atomic_int g_launches_since_last_crash = 0;
static atomic_int g_app_active_time_secs = 0;
static atomic_int g_app_background_time_secs = 0;
static atomic_int g_app_active_time_since_last_crash_secs = 0;
static atomic_int g_app_background_time_since_last_crash_secs = 0;

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

/* Forward declarations. */
static int safe_append(char *buf, int pos, int buflen, const char *str);

/* Signal-safe random hex generator (used for report_id). Reads /dev/urandom. */
static int gen_uuid_hex(char *buf, int buflen) {
    if (buflen < 33) { if (buflen) buf[0] = '\0'; return 0; }
    unsigned char bytes[16];
    int fd = open("/dev/urandom", O_RDONLY);
    int got = 0;
    if (fd >= 0) {
        got = read(fd, bytes, sizeof(bytes));
        close(fd);
    }
    if (got != (int)sizeof(bytes)) {
        memset(bytes, 0, sizeof(bytes));
        long t = time(NULL);
        memcpy(bytes, &t, sizeof(t) < sizeof(bytes) ? sizeof(t) : sizeof(bytes));
    }
    static const char *hex = "0123456789abcdef";
    int p = 0;
    for (int i = 0; i < 16 && p < buflen - 1; i++) {
        buf[p++] = hex[(bytes[i] >> 4) & 0xF];
        buf[p++] = hex[bytes[i] & 0xF];
    }
    buf[p] = '\0';
    return p;
}

/* Count entries in /proc/self/task/ using SYS_getdents64. Signal-safe. */
#ifndef SYS_getdents64
#define SYS_getdents64 217
#endif

struct linux_dirent64_min {
    long           d_ino;
    long           d_off;
    unsigned short d_reclen;
    unsigned char  d_type;
    char           d_name[];
};

static int count_threads(void) {
    int n = 0;
    int dfd = open("/proc/self/task", O_RDONLY | O_DIRECTORY);
    if (dfd < 0) return -1;
    char buf[4096];
    for (;;) {
        long r = syscall(SYS_getdents64, dfd, buf, sizeof(buf));
        if (r <= 0) break;
        long pos = 0;
        while (pos < r) {
            struct linux_dirent64_min *de = (struct linux_dirent64_min *)(buf + pos);
            if (de->d_reclen == 0) break;
            if (de->d_name[0] != '.') n++;
            pos += de->d_reclen;
        }
    }
    close(dfd);
    return n;
}

/* Parse /proc/self/maps into compact JSON array. Caller passes remaining
 * buffer space; we stop short to leave room for the JSON tail. */
static int append_binary_images_json(char *buf, int pos, int buflen, int *out_count) {
    *out_count = 0;
    int fd = open("/proc/self/maps", O_RDONLY);
    if (fd < 0) {
        pos = safe_append(buf, pos, buflen, "[]");
        return pos;
    }
    pos = safe_append(buf, pos, buflen, "[");
    int first = 1;
    char line[512];
    int linelen = 0;
    char chunk[2048];
    for (;;) {
        ssize_t n = read(fd, chunk, sizeof(chunk));
        if (n <= 0) break;
        for (ssize_t i = 0; i < n; i++) {
            if (chunk[i] != '\n' && linelen < (int)sizeof(line) - 1) {
                line[linelen++] = chunk[i];
                continue;
            }
            line[linelen] = '\0';
            int looks_executable = 0;
            for (int k = 0; k < linelen - 4; k++) {
                if (line[k] == ' ' && line[k+3] == 'x') { looks_executable = 1; break; }
            }
            const char *slash = NULL;
            for (int k = linelen - 1; k >= 0; k--) {
                if (line[k] == '/') { slash = line + k; break; }
                if (line[k] == ' ') break;
            }
            if (looks_executable && slash && slash[1] && slash[1] != '[') {
                if (buflen - pos < 200) break;
                char base[20] = {0};
                int bi = 0;
                while (bi < linelen && line[bi] != '-' && bi < (int)sizeof(base) - 1) {
                    base[bi] = line[bi]; bi++;
                }
                base[bi] = '\0';
                if (!first) pos = safe_append(buf, pos, buflen, ",");
                first = 0;
                pos = safe_append(buf, pos, buflen, "{\"base\":\"0x");
                pos = safe_append(buf, pos, buflen, base);
                pos = safe_append(buf, pos, buflen, "\",\"path\":\"");
                const char *p = slash + 1;
                while (*p && pos < buflen - 4) {
                    if (*p == '"' || *p == '\\') {
                        buf[pos++] = '\\';
                    }
                    buf[pos++] = *p++;
                    buf[pos] = '\0';
                }
                pos = safe_append(buf, pos, buflen, "\"}");
                (*out_count)++;
            }
            linelen = 0;
        }
    }
    close(fd);
    pos = safe_append(buf, pos, buflen, "]");
    return pos;
}

/* Format a Unix time as ISO 8601 UTC. Signal-safe (gmtime_r + manual format). */
static int format_iso8601(char *buf, int buflen, time_t t) {
    struct tm tmv;
    gmtime_r(&t, &tmv);
    if (buflen < 25) {
        if (buflen > 0) buf[0] = '\0';
        return 0;
    }
    int y = tmv.tm_year + 1900;
    int mo = tmv.tm_mon + 1;
    int d = tmv.tm_mday;
    int h = tmv.tm_hour;
    int mi = tmv.tm_min;
    int s = tmv.tm_sec;
    int p = 0;
    buf[p++] = '0' + (y / 1000) % 10;
    buf[p++] = '0' + (y / 100) % 10;
    buf[p++] = '0' + (y / 10) % 10;
    buf[p++] = '0' + y % 10;
    buf[p++] = '-';
    buf[p++] = '0' + (mo / 10) % 10;
    buf[p++] = '0' + mo % 10;
    buf[p++] = '-';
    buf[p++] = '0' + (d / 10) % 10;
    buf[p++] = '0' + d % 10;
    buf[p++] = 'T';
    buf[p++] = '0' + (h / 10) % 10;
    buf[p++] = '0' + h % 10;
    buf[p++] = ':';
    buf[p++] = '0' + (mi / 10) % 10;
    buf[p++] = '0' + mi % 10;
    buf[p++] = ':';
    buf[p++] = '0' + (s / 10) % 10;
    buf[p++] = '0' + s % 10;
    buf[p++] = '.';
    buf[p++] = '0';
    buf[p++] = '0';
    buf[p++] = '0';
    buf[p++] = 'Z';
    buf[p] = '\0';
    return p;
}

/* Read MemFree from /proc/meminfo. Returns bytes (kB * 1024) or -1.
 * Signal-safe: only open/read/close + integer parse. */
static long read_meminfo_free_bytes(void) {
    int fd = open("/proc/meminfo", O_RDONLY);
    if (fd < 0) return -1;
    char buf[1024];
    ssize_t n = read(fd, buf, sizeof(buf) - 1);
    close(fd);
    if (n <= 0) return -1;
    buf[n] = '\0';
    const char *needle = "MemFree:";
    char *p = strstr(buf, needle);
    if (!p) return -1;
    p += strlen(needle);
    while (*p == ' ' || *p == '\t') p++;
    long kb = 0;
    while (*p >= '0' && *p <= '9') {
        kb = kb * 10 + (*p - '0');
        p++;
    }
    return kb > 0 ? kb * 1024 : -1;
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

    /* Kernel release populated at install time via uname() — reliable
     * across SELinux changes that block /proc/version on newer Android. */
    const char *kernel_version = g_kernel_release;

    /* Process uptime via clock_gettime(CLOCK_BOOTTIME) — async-signal-safe
     * and doesn't depend on /proc/self/stat (which may be blocked). */
    long uptime_secs = -1;
    {
        struct timespec now;
        if (clock_gettime(CLOCK_BOOTTIME, &now) == 0 && g_proc_start_boottime_secs > 0) {
            uptime_secs = now.tv_sec - g_proc_start_boottime_secs;
            if (uptime_secs < 0) uptime_secs = 0;
        }
    }

    long mem_free_bytes = read_meminfo_free_bytes();
    int foreground = atomic_load(&g_in_foreground);
    int active = atomic_load(&g_app_active);
    int sessions_since_launch = atomic_load(&g_sessions_since_launch);
    int sessions_since_last_crash = atomic_load(&g_sessions_since_last_crash);
    int launches_since_last_crash = atomic_load(&g_launches_since_last_crash);
    int active_time_secs = atomic_load(&g_app_active_time_secs);
    int background_time_secs = atomic_load(&g_app_background_time_secs);
    int active_time_since_last_crash_secs = atomic_load(&g_app_active_time_since_last_crash_secs);
    int background_time_since_last_crash_secs = atomic_load(&g_app_background_time_since_last_crash_secs);
    int thread_count = count_threads();
    long fault_addr = info ? (long)(uintptr_t)info->si_addr : 0;
    int si_code_int = info ? info->si_code : 0;
    char ts_iso[28];
    format_iso8601(ts_iso, sizeof(ts_iso), time(NULL));
    char boot_iso[28];
    if (g_system_boot_time_secs > 0) {
        format_iso8601(boot_iso, sizeof(boot_iso), (time_t)g_system_boot_time_secs);
    } else {
        boot_iso[0] = '\0';
    }
    char report_id[40];
    gen_uuid_hex(report_id, sizeof(report_id));

    /* Build JSON crash report */
    static char buf[32768];
    int bpos = 0;
    bpos = safe_append(buf, bpos, sizeof(buf), "{\"crash_type\":\"native_signal\",\"crash_reason\":\"");
    bpos = safe_append(buf, bpos, sizeof(buf), signal_name(sig));
    bpos = safe_append(buf, bpos, sizeof(buf), "\",\"crash_signal_code\":\"");
    bpos = safe_append(buf, bpos, sizeof(buf), signal_code_name(sig, info ? info->si_code : 0));
    bpos = safe_append(buf, bpos, sizeof(buf), "\",\"crash_timestamp\":\"");
    bpos = safe_append(buf, bpos, sizeof(buf), ts_iso);

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

    bpos = safe_append(buf, bpos, sizeof(buf), ",\"crash_cpu_arch\":\"");
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
        bpos = safe_append(buf, bpos, sizeof(buf), ",\"crash_kernel_version\":\"");
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

    if (uptime_secs >= 0) {
        bpos = safe_append(buf, bpos, sizeof(buf), ",\"crash_process_uptime_secs\":");
        char uptimebuf[12];
        int_to_str(uptimebuf, sizeof(uptimebuf), uptime_secs);
        bpos = safe_append(buf, bpos, sizeof(buf), uptimebuf);
    }
    {
        struct timespec since_boot;
        if (clock_gettime(CLOCK_BOOTTIME, &since_boot) == 0) {
            bpos = safe_append(buf, bpos, sizeof(buf), ",\"crash_time_since_boot_secs\":");
            char sbbuf[16];
            int_to_str(sbbuf, sizeof(sbbuf), (long)since_boot.tv_sec);
            bpos = safe_append(buf, bpos, sizeof(buf), sbbuf);
        }
    }

    /* Register dump */
    bpos = safe_append(buf, bpos, sizeof(buf), ",\"crash_registers_json\":\"");
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
    bpos = safe_append(buf, bpos, sizeof(buf), "\"");

    if (g_machine[0]) {
        bpos = safe_append(buf, bpos, sizeof(buf), ",\"crash_machine\":\"");
        bpos = safe_append(buf, bpos, sizeof(buf), g_machine);
        bpos = safe_append(buf, bpos, sizeof(buf), "\"");
    }
    bpos = safe_append(buf, bpos, sizeof(buf), ",\"crash_os_name\":\"Android\"");
    if (g_os_version[0]) {
        bpos = safe_append(buf, bpos, sizeof(buf), ",\"crash_os_version\":\"");
        bpos = safe_append(buf, bpos, sizeof(buf), g_os_version);
        bpos = safe_append(buf, bpos, sizeof(buf), "\"");
    }
    if (g_app_uuid[0]) {
        bpos = safe_append(buf, bpos, sizeof(buf), ",\"crash_app_uuid\":\"");
        bpos = safe_append(buf, bpos, sizeof(buf), g_app_uuid);
        bpos = safe_append(buf, bpos, sizeof(buf), "\"");
    }
    if (g_bundle_version[0]) {
        bpos = safe_append(buf, bpos, sizeof(buf), ",\"crash_bundle_version\":\"");
        bpos = safe_append(buf, bpos, sizeof(buf), g_bundle_version);
        bpos = safe_append(buf, bpos, sizeof(buf), "\"");
    }
    if (g_parent_proc_name[0]) {
        bpos = safe_append(buf, bpos, sizeof(buf), ",\"crash_parent_proc_name\":\"");
        bpos = safe_append(buf, bpos, sizeof(buf), g_parent_proc_name);
        bpos = safe_append(buf, bpos, sizeof(buf), "\"");
    }
    if (g_parent_pid > 0) {
        bpos = safe_append(buf, bpos, sizeof(buf), ",\"crash_parent_pid\":");
        char ppidbuf[12];
        int_to_str(ppidbuf, sizeof(ppidbuf), (long)g_parent_pid);
        bpos = safe_append(buf, bpos, sizeof(buf), ppidbuf);
    }
    bpos = safe_append(buf, bpos, sizeof(buf), ",\"crash_app_in_foreground\":");
    bpos = safe_append(buf, bpos, sizeof(buf), foreground ? "true" : "false");
    bpos = safe_append(buf, bpos, sizeof(buf), ",\"crash_app_sessions_since_launch\":");
    {
        char sslbuf[12];
        int_to_str(sslbuf, sizeof(sslbuf), (long)sessions_since_launch);
        bpos = safe_append(buf, bpos, sizeof(buf), sslbuf);
    }
    bpos = safe_append(buf, bpos, sizeof(buf), ",\"crash_app_sessions_since_last_crash\":");
    {
        char sslcbuf[12];
        int_to_str(sslcbuf, sizeof(sslcbuf), (long)sessions_since_last_crash);
        bpos = safe_append(buf, bpos, sizeof(buf), sslcbuf);
    }
    if (mem_free_bytes >= 0) {
        bpos = safe_append(buf, bpos, sizeof(buf), ",\"crash_memory_free_bytes\":");
        char mfbuf[20];
        int_to_str(mfbuf, sizeof(mfbuf), mem_free_bytes);
        bpos = safe_append(buf, bpos, sizeof(buf), mfbuf);
    }

    if (g_machine[0]) {
        bpos = safe_append(buf, bpos, sizeof(buf), ",\"crash_device_model\":\"");
        bpos = safe_append(buf, bpos, sizeof(buf), g_machine);
        bpos = safe_append(buf, bpos, sizeof(buf), "\"");
    }
    if (g_bundle_id[0]) {
        bpos = safe_append(buf, bpos, sizeof(buf), ",\"crash_bundle_id\":\"");
        bpos = safe_append(buf, bpos, sizeof(buf), g_bundle_id);
        bpos = safe_append(buf, bpos, sizeof(buf), "\"");
    }
    if (g_app_version[0]) {
        bpos = safe_append(buf, bpos, sizeof(buf), ",\"crash_app_version\":\"");
        bpos = safe_append(buf, bpos, sizeof(buf), g_app_version);
        bpos = safe_append(buf, bpos, sizeof(buf), "\"");
    }
    if (g_app_name[0]) {
        bpos = safe_append(buf, bpos, sizeof(buf), ",\"crash_app_name\":\"");
        bpos = safe_append(buf, bpos, sizeof(buf), g_app_name);
        bpos = safe_append(buf, bpos, sizeof(buf), "\"");
    }
    if (g_process_name[0]) {
        bpos = safe_append(buf, bpos, sizeof(buf), ",\"crash_process_name\":\"");
        bpos = safe_append(buf, bpos, sizeof(buf), g_process_name);
        bpos = safe_append(buf, bpos, sizeof(buf), "\"");
    }
    if (g_app_executable[0]) {
        bpos = safe_append(buf, bpos, sizeof(buf), ",\"crash_app_executable\":\"");
        bpos = safe_append(buf, bpos, sizeof(buf), g_app_executable);
        bpos = safe_append(buf, bpos, sizeof(buf), "\"");
    }
    if (g_executable_path[0]) {
        bpos = safe_append(buf, bpos, sizeof(buf), ",\"crash_executable_path\":\"");
        bpos = safe_append(buf, bpos, sizeof(buf), g_executable_path);
        bpos = safe_append(buf, bpos, sizeof(buf), "\"");
    }
    if (g_device_app_hash[0]) {
        bpos = safe_append(buf, bpos, sizeof(buf), ",\"crash_device_app_hash\":\"");
        bpos = safe_append(buf, bpos, sizeof(buf), g_device_app_hash);
        bpos = safe_append(buf, bpos, sizeof(buf), "\"");
    }
    if (g_idfv[0]) {
        bpos = safe_append(buf, bpos, sizeof(buf), ",\"crash_idfv\":\"");
        bpos = safe_append(buf, bpos, sizeof(buf), g_idfv);
        bpos = safe_append(buf, bpos, sizeof(buf), "\"");
    }
    if (g_build_type[0]) {
        bpos = safe_append(buf, bpos, sizeof(buf), ",\"crash_build_type\":\"");
        bpos = safe_append(buf, bpos, sizeof(buf), g_build_type);
        bpos = safe_append(buf, bpos, sizeof(buf), "\"");
    }
    if (g_environment[0]) {
        bpos = safe_append(buf, bpos, sizeof(buf), ",\"crash_environment\":\"");
        bpos = safe_append(buf, bpos, sizeof(buf), g_environment);
        bpos = safe_append(buf, bpos, sizeof(buf), "\"");
    }
    if (g_build_configuration[0]) {
        bpos = safe_append(buf, bpos, sizeof(buf), ",\"crash_build_configuration\":\"");
        bpos = safe_append(buf, bpos, sizeof(buf), g_build_configuration);
        bpos = safe_append(buf, bpos, sizeof(buf), "\"");
    }
    if (g_os_build[0]) {
        bpos = safe_append(buf, bpos, sizeof(buf), ",\"crash_os_build\":\"");
        bpos = safe_append(buf, bpos, sizeof(buf), g_os_build);
        bpos = safe_append(buf, bpos, sizeof(buf), "\"");
    }
    if (g_time_zone[0]) {
        bpos = safe_append(buf, bpos, sizeof(buf), ",\"crash_time_zone\":\"");
        bpos = safe_append(buf, bpos, sizeof(buf), g_time_zone);
        bpos = safe_append(buf, bpos, sizeof(buf), "\"");
    }
    if (boot_iso[0]) {
        bpos = safe_append(buf, bpos, sizeof(buf), ",\"crash_system_boot_time_iso\":\"");
        bpos = safe_append(buf, bpos, sizeof(buf), boot_iso);
        bpos = safe_append(buf, bpos, sizeof(buf), "\"");
    }
    if (g_app_start_time_secs > 0) {
        char as_iso[28];
        format_iso8601(as_iso, sizeof(as_iso), (time_t)g_app_start_time_secs);
        bpos = safe_append(buf, bpos, sizeof(buf), ",\"crash_app_start_time\":\"");
        bpos = safe_append(buf, bpos, sizeof(buf), as_iso);
        bpos = safe_append(buf, bpos, sizeof(buf), "\"");
    }
    bpos = safe_append(buf, bpos, sizeof(buf), ",\"crash_translated\":");
    bpos = safe_append(buf, bpos, sizeof(buf), g_translated ? "true" : "false");
    if (g_gid >= 0) {
        bpos = safe_append(buf, bpos, sizeof(buf), ",\"crash_gid\":");
        char gidbuf[12];
        int_to_str(gidbuf, sizeof(gidbuf), (long)g_gid);
        bpos = safe_append(buf, bpos, sizeof(buf), gidbuf);
    }

    bpos = safe_append(buf, bpos, sizeof(buf), ",\"crash_signal\":\"");
    bpos = safe_append(buf, bpos, sizeof(buf), signal_name(sig));
    bpos = safe_append(buf, bpos, sizeof(buf), "\",\"crash_signal_number\":");
    {
        char snbuf[8];
        int_to_str(snbuf, sizeof(snbuf), (long)sig);
        bpos = safe_append(buf, bpos, sizeof(buf), snbuf);
    }
    bpos = safe_append(buf, bpos, sizeof(buf), ",\"crash_signal_code\":");
    {
        char scbuf[12];
        int_to_str(scbuf, sizeof(scbuf), (long)si_code_int);
        bpos = safe_append(buf, bpos, sizeof(buf), scbuf);
    }
    if (info) {
        bpos = safe_append(buf, bpos, sizeof(buf), ",\"crash_fault_address\":\"0x");
        char fahex[20];
        ulong_to_hex(fahex, sizeof(fahex), (unsigned long)fault_addr);
        bpos = safe_append(buf, bpos, sizeof(buf), fahex);
        bpos = safe_append(buf, bpos, sizeof(buf), "\"");
    }
    bpos = safe_append(buf, bpos, sizeof(buf), ",\"crash_signal_code_name\":\"");
    bpos = safe_append(buf, bpos, sizeof(buf), signal_code_name(sig, si_code_int));
    bpos = safe_append(buf, bpos, sizeof(buf), "\"");

    if (thread_count > 0) {
        bpos = safe_append(buf, bpos, sizeof(buf), ",\"crash_thread_count\":");
        char tcbuf[8];
        int_to_str(tcbuf, sizeof(tcbuf), (long)thread_count);
        bpos = safe_append(buf, bpos, sizeof(buf), tcbuf);
    }
    bpos = safe_append(buf, bpos, sizeof(buf), ",\"crash_thread_index\":0");

#if defined(__aarch64__)
    bpos = safe_append(buf, bpos, sizeof(buf), ",\"crash_exception_register\":\"x16: 0x");
    {
        char xhex[20];
        ulong_to_hex(xhex, sizeof(xhex), (unsigned long)uc->uc_mcontext.regs[16]);
        bpos = safe_append(buf, bpos, sizeof(buf), xhex);
        bpos = safe_append(buf, bpos, sizeof(buf), " x17: 0x");
        ulong_to_hex(xhex, sizeof(xhex), (unsigned long)uc->uc_mcontext.regs[17]);
        bpos = safe_append(buf, bpos, sizeof(buf), xhex);
    }
    bpos = safe_append(buf, bpos, sizeof(buf), "\"");
#endif

    bpos = safe_append(buf, bpos, sizeof(buf), ",\"crash_app_active\":");
    bpos = safe_append(buf, bpos, sizeof(buf), active ? "true" : "false");
    bpos = safe_append(buf, bpos, sizeof(buf), ",\"crash_app_active_time_secs\":");
    {
        char x[12]; int_to_str(x, sizeof(x), (long)active_time_secs);
        bpos = safe_append(buf, bpos, sizeof(buf), x);
    }
    bpos = safe_append(buf, bpos, sizeof(buf), ",\"crash_app_background_time_secs\":");
    {
        char x[12]; int_to_str(x, sizeof(x), (long)background_time_secs);
        bpos = safe_append(buf, bpos, sizeof(buf), x);
    }
    bpos = safe_append(buf, bpos, sizeof(buf), ",\"crash_app_active_time_since_last_crash_secs\":");
    {
        char x[12]; int_to_str(x, sizeof(x), (long)active_time_since_last_crash_secs);
        bpos = safe_append(buf, bpos, sizeof(buf), x);
    }
    bpos = safe_append(buf, bpos, sizeof(buf), ",\"crash_app_background_time_since_last_crash_secs\":");
    {
        char x[12]; int_to_str(x, sizeof(x), (long)background_time_since_last_crash_secs);
        bpos = safe_append(buf, bpos, sizeof(buf), x);
    }
    bpos = safe_append(buf, bpos, sizeof(buf), ",\"crash_app_launches_since_last_crash\":");
    {
        char x[12]; int_to_str(x, sizeof(x), (long)launches_since_last_crash);
        bpos = safe_append(buf, bpos, sizeof(buf), x);
    }

    if (g_memory_size_bytes > 0) {
        bpos = safe_append(buf, bpos, sizeof(buf), ",\"crash_memory_size_bytes\":");
        char x[20]; int_to_str(x, sizeof(x), g_memory_size_bytes);
        bpos = safe_append(buf, bpos, sizeof(buf), x);
    }
    if (g_storage_size_bytes > 0) {
        bpos = safe_append(buf, bpos, sizeof(buf), ",\"crash_storage_size_bytes\":");
        char x[20]; int_to_str(x, sizeof(x), g_storage_size_bytes);
        bpos = safe_append(buf, bpos, sizeof(buf), x);
    }
    if (g_storage_free_bytes >= 0) {
        bpos = safe_append(buf, bpos, sizeof(buf), ",\"crash_storage_free_bytes\":");
        char x[20]; int_to_str(x, sizeof(x), g_storage_free_bytes);
        bpos = safe_append(buf, bpos, sizeof(buf), x);
    }

    bpos = safe_append(buf, bpos, sizeof(buf), ",\"crash_report_id\":\"");
    bpos = safe_append(buf, bpos, sizeof(buf), report_id);
    bpos = safe_append(buf, bpos, sizeof(buf), "\",\"crash_report_type\":\"native_signal\",\"crash_report_version\":\"1.0\"");

    {
        int images_count = 0;
        bpos = safe_append(buf, bpos, sizeof(buf), ",\"crash_binary_images_json\":");
        int saved = bpos;
        bpos = append_binary_images_json(buf, bpos, sizeof(buf), &images_count);
        if (bpos == saved) {
            bpos = safe_append(buf, bpos, sizeof(buf), "[]");
        }
        bpos = safe_append(buf, bpos, sizeof(buf), ",\"crash_binary_images_count\":");
        char icbuf[12];
        int_to_str(icbuf, sizeof(icbuf), (long)images_count);
        bpos = safe_append(buf, bpos, sizeof(buf), icbuf);
    }

    bpos = safe_append(buf, bpos, sizeof(buf), "}");

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

static void copy_jstring(JNIEnv *env, jstring s, char *dst, size_t dst_sz) {
    if (!s || dst_sz == 0) { if (dst_sz) dst[0] = '\0'; return; }
    const char *p = (*env)->GetStringUTFChars(env, s, NULL);
    if (!p) { dst[0] = '\0'; return; }
    size_t i = 0;
    while (p[i] && i < dst_sz - 1) { dst[i] = p[i]; i++; }
    dst[i] = '\0';
    (*env)->ReleaseStringUTFChars(env, s, p);
}

JNIEXPORT void JNICALL
Java_com_base14_scout_1flutter_CrashReporter_nativeSetContext(
    JNIEnv *env, jclass clazz,
    jstring model, jstring osVersion, jstring appUuid,
    jstring bundleVersion, jstring parentName, jint parentPid
) {
    (void)clazz;
    copy_jstring(env, model, g_machine, sizeof(g_machine));
    copy_jstring(env, osVersion, g_os_version, sizeof(g_os_version));
    copy_jstring(env, appUuid, g_app_uuid, sizeof(g_app_uuid));
    copy_jstring(env, bundleVersion, g_bundle_version, sizeof(g_bundle_version));
    copy_jstring(env, parentName, g_parent_proc_name, sizeof(g_parent_proc_name));
    g_parent_pid = (int)parentPid;
}

JNIEXPORT void JNICALL
Java_com_base14_scout_1flutter_CrashReporter_nativeSetForegroundState(
    JNIEnv *env, jclass clazz, jboolean inForeground, jboolean active
) {
    (void)env;
    (void)clazz;
    atomic_store(&g_in_foreground, inForeground ? 1 : 0);
    atomic_store(&g_app_active, active ? 1 : 0);
}

JNIEXPORT void JNICALL
Java_com_base14_scout_1flutter_CrashReporter_nativeSetExtendedContext(
    JNIEnv *env, jclass clazz,
    jstring processName, jstring appName, jstring appExecutable,
    jstring executablePath, jstring appVersion, jstring bundleId,
    jstring deviceAppHash, jstring idfv, jstring buildType,
    jstring environment, jstring buildConfiguration, jstring osBuild,
    jstring timeZone, jboolean translated, jint gid,
    jlong appStartTimeSecs, jlong systemBootTimeSecs
) {
    (void)clazz;
    copy_jstring(env, processName, g_process_name, sizeof(g_process_name));
    copy_jstring(env, appName, g_app_name, sizeof(g_app_name));
    copy_jstring(env, appExecutable, g_app_executable, sizeof(g_app_executable));
    copy_jstring(env, executablePath, g_executable_path, sizeof(g_executable_path));
    copy_jstring(env, appVersion, g_app_version, sizeof(g_app_version));
    copy_jstring(env, bundleId, g_bundle_id, sizeof(g_bundle_id));
    copy_jstring(env, deviceAppHash, g_device_app_hash, sizeof(g_device_app_hash));
    copy_jstring(env, idfv, g_idfv, sizeof(g_idfv));
    copy_jstring(env, buildType, g_build_type, sizeof(g_build_type));
    copy_jstring(env, environment, g_environment, sizeof(g_environment));
    copy_jstring(env, buildConfiguration, g_build_configuration, sizeof(g_build_configuration));
    copy_jstring(env, osBuild, g_os_build, sizeof(g_os_build));
    copy_jstring(env, timeZone, g_time_zone, sizeof(g_time_zone));
    g_translated = translated ? 1 : 0;
    g_gid = (int)gid;
    g_app_start_time_secs = (long)appStartTimeSecs;
    g_system_boot_time_secs = (long)systemBootTimeSecs;
}

JNIEXPORT void JNICALL
Java_com_base14_scout_1flutter_CrashReporter_nativeSetMemoryInfo(
    JNIEnv *env, jclass clazz,
    jlong memorySizeBytes, jlong storageSizeBytes, jlong storageFreeBytes
) {
    (void)env;
    (void)clazz;
    g_memory_size_bytes = (long)memorySizeBytes;
    g_storage_size_bytes = (long)storageSizeBytes;
    g_storage_free_bytes = (long)storageFreeBytes;
}

JNIEXPORT void JNICALL
Java_com_base14_scout_1flutter_CrashReporter_nativeSetActivityTimers(
    JNIEnv *env, jclass clazz,
    jint activeTimeSecs, jint backgroundTimeSecs,
    jint activeSinceLastCrashSecs, jint backgroundSinceLastCrashSecs,
    jint launchesSinceLastCrash
) {
    (void)env;
    (void)clazz;
    atomic_store(&g_app_active_time_secs, (int)activeTimeSecs);
    atomic_store(&g_app_background_time_secs, (int)backgroundTimeSecs);
    atomic_store(&g_app_active_time_since_last_crash_secs, (int)activeSinceLastCrashSecs);
    atomic_store(&g_app_background_time_since_last_crash_secs, (int)backgroundSinceLastCrashSecs);
    atomic_store(&g_launches_since_last_crash, (int)launchesSinceLastCrash);
}

JNIEXPORT void JNICALL
Java_com_base14_scout_1flutter_CrashReporter_nativeSetSessionCounters(
    JNIEnv *env, jclass clazz, jint sinceLaunch, jint sinceLastCrash
) {
    (void)env;
    (void)clazz;
    atomic_store(&g_sessions_since_launch, (int)sinceLaunch);
    atomic_store(&g_sessions_since_last_crash, (int)sinceLastCrash);
}

JNIEXPORT void JNICALL
Java_com_base14_scout_1flutter_CrashReporter_nativeInstallSignalHandler(
    JNIEnv *env, jclass clazz, jstring crashDirPath
) {
    const char *path = (*env)->GetStringUTFChars(env, crashDirPath, NULL);
    if (!path) return;

    int len = strlen(path);
    if (len >= MAX_PATH) len = MAX_PATH - 1;
    memcpy(g_crash_dir, path, len);
    g_crash_dir[len] = '\0';

    (*env)->ReleaseStringUTFChars(env, crashDirPath, path);

    struct utsname u;
    if (uname(&u) == 0) {
        size_t i = 0;
        while (u.release[i] && i < sizeof(g_kernel_release) - 1) {
            g_kernel_release[i] = u.release[i];
            i++;
        }
        g_kernel_release[i] = '\0';
    }

    struct timespec ts_now;
    if (clock_gettime(CLOCK_BOOTTIME, &ts_now) == 0) {
        g_proc_start_boottime_secs = ts_now.tv_sec;
    }

    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sigemptyset(&sa.sa_mask);
    sa.sa_sigaction = crash_signal_handler;
    sa.sa_flags = SA_SIGINFO | SA_ONSTACK;

    for (int i = 0; i < g_signal_count; i++) {
        sigaction(g_signals[i], &sa, &g_old_handlers[g_signals[i]]);
    }
}
