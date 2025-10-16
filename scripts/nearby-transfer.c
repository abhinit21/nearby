/* Nearby's narrowly scoped Android Downloads helper.
 * Never copies into a final name and never uses a check-then-rename operation.
 * Linux renameat2(RENAME_NOREPLACE) is the only supported finalization path.
 */
#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <sys/types.h>
#include <unistd.h>
#if defined(__APPLE__) && defined(NEARBY_TRANSFER_HOST_TEST)
#include <sys/stdio.h>
#else
#include <sys/syscall.h>
#endif

#define STORAGE 21
#define PERMISSION 22
#define UNSUPPORTED 23
#define NAME 24
#define DUPLICATES 25
#define OWNERSHIP 26
#define CHANGED 27
#define IO_ERROR 28

static int failure(int fallback) {
    if (errno == ENOSPC || errno == EDQUOT) return STORAGE;
    if (errno == EACCES || errno == EPERM || errno == EROFS) return PERMISSION;
    if (errno == ENAMETOOLONG || errno == EINVAL) return NAME;
    return fallback;
}

static int valid_token(const char *s) {
    if (strlen(s) != 36) return 0;
    for (int i = 0; i < 36; ++i) {
        if (i == 8 || i == 13 || i == 18 || i == 23) { if (s[i] != '-') return 0; }
        else if (!((s[i] >= '0' && s[i] <= '9') || (s[i] >= 'a' && s[i] <= 'f'))) return 0;
    }
    return 1;
}

static int open_downloads(void) {
    const char *path = "/sdcard/Download";
#if defined(NEARBY_TRANSFER_HOST_TEST)
    const char *override = getenv("NEARBY_TEST_DOWNLOADS");
    if (override) path = override;
#endif
    if (mkdir(path, 0770) < 0 && errno != EEXIST) return -1;
    return open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
}

static int owned_stage(int root, const char *stage_name, const char *token) {
    int stage = openat(root, stage_name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (stage < 0) return -1;
    int marker = openat(stage, ".owner", O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
    struct stat info;
    char content[38] = {0};
    ssize_t count = marker < 0 ? -1 : read(marker, content, sizeof(content));
    int valid = marker >= 0 && fstat(marker, &info) == 0 && S_ISREG(info.st_mode) &&
        info.st_size == 36 && count == 36 && memcmp(content, token, 36) == 0;
    if (marker >= 0) close(marker);
    if (!valid) { close(stage); errno = EINVAL; return -1; }
    return stage;
}

static int prepare(int root, const char *stage_name, const char *token, uint64_t size) {
    struct statvfs space;
    if (fstatvfs(root, &space) < 0) return failure(IO_ERROR);
    uint64_t unit = space.f_frsize ? space.f_frsize : space.f_bsize;
    if (!unit) return IO_ERROR;
    uint64_t available = space.f_bavail > UINT64_MAX / unit ? UINT64_MAX :
        (uint64_t)space.f_bavail * unit;
    if (available < size || available - size < 1048576) return STORAGE;
    // No -p: a collision does not grant ownership of any pre-existing directory.
    if (mkdirat(root, stage_name, 0700) < 0) return failure(OWNERSHIP);
    int stage = openat(root, stage_name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (stage < 0) return failure(OWNERSHIP);
    int marker = openat(stage, ".owner", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    int result = 0;
    if (marker < 0 || write(marker, token, 36) != 36) result = failure(IO_ERROR);
    if (marker >= 0) close(marker);
    // Payload is created only by the SYNC uploader, after ownership is durable.
    close(stage);
    if (result) return result;
    printf("OK");
    return 0;
}

static int rename_exclusive(int from, const char *source, int to, const char *destination) {
#if defined(__APPLE__) && defined(NEARBY_TRANSFER_HOST_TEST)
    return renameatx_np(from, source, to, destination, RENAME_EXCL);
#else
    return (int)syscall(SYS_renameat2, from, source, to, destination, 1 /* RENAME_NOREPLACE */);
#endif
}

/* Truncate only at a UTF-8 boundary when a duplicate suffix needs name space. */
static size_t prefix_length(const char *text, size_t length, size_t maximum) {
    if (length <= maximum) return length;
    size_t cut = maximum;
    while (cut > 0 && (((unsigned char)text[cut] & 0xc0) == 0x80)) --cut;
    return cut;
}

static int commit(int root, const char *stage_name, const char *token, const char *name, uint64_t expected) {
    size_t length = strlen(name);
    if (!length || length > 255 || !strcmp(name, ".") || !strcmp(name, "..") || strchr(name, '/')) return NAME;
    int stage = owned_stage(root, stage_name, token);
    if (stage < 0) return OWNERSHIP;
    int payload = openat(stage, "payload.partial", O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
    struct stat info;
    if (payload < 0 || fstat(payload, &info) < 0 || !S_ISREG(info.st_mode)) {
        if (payload >= 0) close(payload); close(stage); return OWNERSHIP;
    }
    if ((uint64_t)info.st_size != expected) { close(payload); close(stage); return CHANGED; }
    if (fsync(payload) < 0 && errno != EINVAL) { int rc = failure(IO_ERROR); close(payload); close(stage); return rc; }
    close(payload);
    const char *extension = strrchr(name, '.');
    if (extension == name) extension = NULL;
    size_t stem_length = extension ? (size_t)(extension - name) : length;
    size_t extension_length = extension ? strlen(extension) : 0;
    char candidate[256];
    int result = DUPLICATES;
    for (unsigned attempt = 1; attempt <= 10000; ++attempt) {
        if (attempt == 1) memcpy(candidate, name, length + 1);
        else {
            char suffix[32];
            snprintf(suffix, sizeof(suffix), " (%u)", attempt);
            size_t suffix_length = strlen(suffix);
            // A pathological 250-byte extension also needs room for the suffix.
            size_t keep_extension = prefix_length(extension ? extension : "", extension_length, 255 - suffix_length - 1);
            size_t keep_stem = prefix_length(name, stem_length, 255 - suffix_length - keep_extension);
            memcpy(candidate, name, keep_stem);
            memcpy(candidate + keep_stem, suffix, suffix_length);
            if (keep_extension) memcpy(candidate + keep_stem + suffix_length, extension, keep_extension);
            candidate[keep_stem + suffix_length + keep_extension] = 0;
        }
        // Existing files, directories, and symlinks all produce EEXIST without
        // touching either path, including when a destination appears concurrently.
        if (rename_exclusive(stage, "payload.partial", root, candidate) == 0) {
            printf("OK\t%s", candidate); result = 0; break;
        }
        if (errno == EEXIST || errno == ENOTEMPTY) continue;
        if (errno == ENOSYS || errno == EOPNOTSUPP || errno == EINVAL || errno == EXDEV) result = UNSUPPORTED;
        else result = failure(IO_ERROR);
        break;
    }
    close(stage);
    return result;
}

static int cleanup(int root, const char *stage_name, const char *token) {
    int stage = owned_stage(root, stage_name, token);
    if (stage < 0) {
        if (errno == ENOENT) { printf("OK"); return 0; }
        return OWNERSHIP;
    }
    struct stat payload;
    if (fstatat(stage, "payload.partial", &payload, AT_SYMLINK_NOFOLLOW) == 0) {
        // Refuse symlinks and directories. Only the regular uploader-created
        // partial can be deleted; final Downloads filenames are never accepted.
        if (!S_ISREG(payload.st_mode)) { close(stage); return OWNERSHIP; }
        if (unlinkat(stage, "payload.partial", 0) < 0) { int rc = failure(IO_ERROR); close(stage); return rc; }
    } else if (errno != ENOENT) { int rc = failure(IO_ERROR); close(stage); return rc; }
    // Do not remove any other entries. Keep the marker if someone has placed an
    // unrelated file in this folder, and leave that folder entirely intact.
    DIR *entries = fdopendir(dup(stage));
    if (!entries) { close(stage); return IO_ERROR; }
    int foreign = 0;
    struct dirent *entry;
    while ((entry = readdir(entries))) {
        if (strcmp(entry->d_name, ".") && strcmp(entry->d_name, "..") && strcmp(entry->d_name, ".owner")) foreign = 1;
    }
    closedir(entries);
    if (!foreign) {
        if (unlinkat(stage, ".owner", 0) < 0) { int rc = failure(IO_ERROR); close(stage); return rc; }
        // An unexpected foreign file arriving now makes rmdir fail safely.
        if (unlinkat(root, stage_name, AT_REMOVEDIR) < 0 && errno != ENOTEMPTY && errno != ENOENT) {
            int rc = failure(IO_ERROR); close(stage); return rc;
        }
    }
    close(stage); printf("OK"); return 0;
}

static int parse_size(const char *input, uint64_t *value) {
    if (!input[0]) return 0;
    for (const char *p = input; *p; ++p) if (*p < '0' || *p > '9') return 0;
    errno = 0;
    char *end = NULL;
    *value = strtoull(input, &end, 10);
    return !errno && end && !*end && *value <= INT64_MAX;
}

int main(int argc, char **argv) {
    if (argc < 3 || !valid_token(argv[2])) return OWNERSHIP;
    int root = open_downloads();
    if (root < 0) return failure(OWNERSHIP);
    char stage_name[64];
    snprintf(stage_name, sizeof(stage_name), ".nearby-transfer-%s", argv[2]);
    int result = OWNERSHIP;
    uint64_t size = 0;
    if (!strcmp(argv[1], "prepare") && argc == 4 && parse_size(argv[3], &size))
        result = prepare(root, stage_name, argv[2], size);
    else if (!strcmp(argv[1], "commit") && argc == 5 && parse_size(argv[4], &size))
        result = commit(root, stage_name, argv[2], argv[3], size);
    else if (!strcmp(argv[1], "cleanup") && argc == 3)
        result = cleanup(root, stage_name, argv[2]);
    close(root);
    return result;
}
