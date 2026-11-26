#include "ArchiveEngine.h"

#include <fcntl.h>
#include <locale.h>
#include <limits.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "SystemLibarchive.h"

static void report_error(char *output, size_t capacity, const char *message,
                         struct archive *archive) {
    const char *detail = archive ? archive_error_string(archive) : NULL;
    if (detail) {
        snprintf(output, capacity, "%s\n%s", message, detail);
    } else {
        snprintf(output, capacity, "%s", message);
    }
}

static bool safe_member_path(const char *path) {
    if (!path || !*path || *path == '/') {
        return false;
    }
    while (*path) {
        size_t length = strcspn(path, "/");
        if (length == 2 && path[0] == '.' && path[1] == '.') {
            return false;
        }
        path += length;
        if (*path == '/') {
            ++path;
        }
    }
    return true;
}

// A framework contains relative symlinks. Keep libarchive's no-follow write
// protection, then verify every link after extraction, before publication.
struct extracted_link {
    char *path;
    struct extracted_link *next;
};

static bool safe_link_target(const char *member, const char *target) {
    if (!target || !*target || *target == '/') return false;
    size_t depth = 0;
    for (const char *p = member; *p; ++p) if (*p == '/') ++depth;
    while (*target) {
        size_t n = strcspn(target, "/");
        if (n == 2 && target[0] == '.' && target[1] == '.') {
            if (!depth) return false;
            --depth;
        } else if (n && !(n == 1 && target[0] == '.')) {
            ++depth;
        }
        target += n;
        if (*target) ++target;
    }
    return true;
}

int extract_archive(const char *source, const char *staging,
                    const char *stream_name, char *error, size_t error_size) {
    int result = -1;
    int fd = -1;
    struct archive *reader = NULL;
    struct archive *writer = NULL;
    struct stat source_stat;
    bool empty_stream = false;
    struct extracted_link *links = NULL;
    // macOS /var and /tmp are symlinks. Canonicalize the staging parent so
    // libarchive's secure-symlinks check only sees links from the archive.
    char canonical_staging[PATH_MAX];
    if (!realpath(staging, canonical_staging)) {
        report_error(error, error_size, "无法读取解压目录。", NULL);
        return -1;
    }
    staging = canonical_staging;
    locale_t utf8 = newlocale(LC_CTYPE_MASK, "en_US.UTF-8", NULL);
    locale_t previous_locale = utf8 ? uselocale(utf8) : NULL;

    fd = open(source, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0 || fstat(fd, &source_stat) < 0 || !S_ISREG(source_stat.st_mode)) {
        report_error(error, error_size, "无法读取压缩包。", NULL);
        goto finish;
    }
    if (source_stat.st_size == 0) {
        report_error(error, error_size, "压缩包是空文件。", NULL);
        goto finish;
    }

    reader = archive_read_new();
    writer = archive_write_disk_new();
    if (!reader || !writer) {
        report_error(error, error_size, "无法初始化解压。", NULL);
        goto finish;
    }

    if (stream_name) {
        archive_read_support_format_raw(reader);
        archive_read_support_format_empty(reader);
    } else {
        archive_read_support_format_7zip(reader);
        archive_read_support_format_rar(reader);
        archive_read_support_format_rar5(reader);
        archive_read_support_format_tar(reader);
        archive_read_support_format_zip(reader);
        archive_read_support_format_cab(reader);
        archive_read_support_format_cpio(reader);
        archive_read_support_format_lha(reader);
        archive_read_support_format_ar(reader);
        archive_read_support_format_xar(reader);
    }

    archive_read_support_filter_gzip(reader);
    archive_read_support_filter_bzip2(reader);
    archive_read_support_filter_xz(reader);
    archive_read_support_filter_compress(reader);
    archive_read_support_filter_lzip(reader);
    archive_read_support_filter_lzma(reader);

    archive_write_disk_set_options(writer,
        ARCHIVE_EXTRACT_TIME | ARCHIVE_EXTRACT_SPARSE |
        ARCHIVE_EXTRACT_SECURE_SYMLINKS | ARCHIVE_EXTRACT_SECURE_NODOTDOT |
        ARCHIVE_EXTRACT_NO_OVERWRITE);

    if (archive_read_open_fd(reader, fd, 64 * 1024) != ARCHIVE_OK) {
        report_error(error, error_size, "无法读取压缩包。它可能已损坏或使用了不支持的格式。", reader);
        goto finish;
    }

    struct archive_entry *entry;
    int status;
    while ((status = archive_read_next_header(reader, &entry)) == ARCHIVE_OK) {
        mode_t type = archive_entry_filetype(entry);
        const char *member = archive_entry_pathname(entry);
        if (archive_format(reader) == ARCHIVE_FORMAT_RAW) {
            if (!stream_name || archive_filter_code(reader, 0) == ARCHIVE_FILTER_NONE) {
                report_error(error, error_size, "文件没有可识别的压缩数据。", NULL);
                goto finish;
            }
            member = stream_name;
        }
        if (archive_entry_is_encrypted(entry)) {
            report_error(error, error_size, "此版本无法解压需要密码的压缩包。", NULL);
            goto finish;
        }
        if ((type != S_IFREG && type != S_IFDIR && type != S_IFLNK)
            || archive_entry_hardlink(entry)) {
            report_error(error, error_size, "压缩包含有不支持的硬链接或特殊文件。", NULL);
            goto finish;
        }
        if (!safe_member_path(member)) {
            report_error(error, error_size, "压缩包含有不安全的文件路径。", NULL);
            goto finish;
        }

        while (member[0] == '.' && member[1] == '/') {
            member += 2;
            while (*member == '/') {
                ++member;
            }
        }
        if (type == S_IFDIR && (!*member || strcmp(member, ".") == 0)) {
            continue;
        }
        if (!*member || strcmp(member, ".") == 0) {
            report_error(error, error_size, "压缩包含有无效的文件名。", NULL);
            goto finish;
        }

        if (type == S_IFLNK && !safe_link_target(member, archive_entry_symlink(entry))) {
            report_error(error, error_size, "压缩包含有指向解压目录之外的链接。", NULL);
            goto finish;
        }
        char *destination = NULL;
        if (asprintf(&destination, "%s/%s", staging, member) < 0) {
            report_error(error, error_size, "无法分配解压所需的内存。", NULL);
            goto finish;
        }
        archive_entry_set_pathname(entry, destination);
        if (type == S_IFLNK) {
            struct extracted_link *link = calloc(1, sizeof(*link));
            if (!link) {
                free(destination);
                report_error(error, error_size, "无法分配解压所需的内存。", NULL);
                goto finish;
            }
            link->path = destination;
            link->next = links;
            links = link;
        } else {
            free(destination);
        }
        archive_entry_set_perm(entry,
            type == S_IFDIR ? 0755 : 0644 | (archive_entry_perm(entry) & 0111));
        if (archive_read_extract2(reader, entry, writer) != ARCHIVE_OK) {
            report_error(error, error_size, "无法写出文件。请检查压缩包、目标目录和可用空间。", reader);
            goto finish;
        }
    }
    if (status != ARCHIVE_EOF) {
        report_error(error, error_size, "无法读取压缩包的全部内容。它可能已损坏、加密或缺少分卷。", reader);
        goto finish;
    }
    if (stream_name && archive_format(reader) == ARCHIVE_FORMAT_EMPTY) {
        if (archive_filter_code(reader, 0) == ARCHIVE_FILTER_NONE) {
            report_error(error, error_size, "文件没有可识别的压缩数据。", NULL);
            goto finish;
        }
        empty_stream = true;
    }
    if (archive_write_close(writer) != ARCHIVE_OK) {
        report_error(error, error_size, "无法完成解压。", writer);
        goto finish;
    }
    if (empty_stream) {
        int target = open(staging, O_DIRECTORY | O_CLOEXEC);
        int item = target < 0 ? -1 :
            openat(target, stream_name, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0644);
        if (target >= 0) {
            close(target);
        }
        if (item < 0) {
            report_error(error, error_size, "无法写出解压后的空文件。", NULL);
            goto finish;
        }
        close(item);
    }
    // realpath follows the complete chain, including parent symlinks. Reject
    // dangling/cyclic links as well as links escaping through another link.
    char root[PATH_MAX];
    if (links && !realpath(staging, root)) {
        report_error(error, error_size, "无法校验解压目录。", NULL);
        goto finish;
    }
    for (struct extracted_link *link = links; link; link = link->next) {
        char resolved[PATH_MAX];
        size_t n = strlen(root);
        // A lone top-level directory is published without its staging parent.
        // Nested links must stay inside that directory so relocation cannot
        // turn a staging-local link into a link to unrelated destination files.
        const char *relative = link->path + strlen(staging) + 1;
        const char *slash = strchr(relative, '/');
        size_t top_length = slash ? (size_t)(slash - relative) : 0;
        if (!realpath(link->path, resolved) ||
            strncmp(root, resolved, n) != 0 || resolved[n] != '/' ||
            (top_length && (strncmp(resolved + n + 1, relative, top_length) != 0 ||
             (resolved[n + 1 + top_length] != '/' && resolved[n + 1 + top_length] != '\0')))) {
            report_error(error, error_size, "压缩包的链接无效或指向解压目录之外。", NULL);
            goto finish;
        }
    }
    result = 0;

finish:
    while (links) {
        struct extracted_link *next = links->next;
        free(links->path);
        free(links);
        links = next;
    }
    if (writer) {
        archive_write_free(writer);
    }
    if (reader) {
        archive_read_free(reader);
    }
    if (fd >= 0) {
        close(fd);
    }
    if (previous_locale) {
        uselocale(previous_locale);
    }
    if (utf8) {
        freelocale(utf8);
    }
    return result;
}
