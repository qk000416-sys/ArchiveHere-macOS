#ifndef ARCHIVE_HERE_SYSTEM_LIBARCHIVE_H
#define ARCHIVE_HERE_SYSTEM_LIBARCHIVE_H

// Some macOS SDKs ship the libarchive linker stub without public headers.
#if __has_include(<archive.h>) && __has_include(<archive_entry.h>)
#include <archive.h>
#include <archive_entry.h>
#else
#include <stddef.h>
#include <sys/types.h>

struct archive;
struct archive_entry;

#define ARCHIVE_EOF 1
#define ARCHIVE_OK 0
#define ARCHIVE_FILTER_NONE 0
#define ARCHIVE_FORMAT_EMPTY 0x60000
#define ARCHIVE_FORMAT_RAW 0x90000
#define ARCHIVE_EXTRACT_TIME 0x0004
#define ARCHIVE_EXTRACT_NO_OVERWRITE 0x0008
#define ARCHIVE_EXTRACT_SECURE_SYMLINKS 0x0100
#define ARCHIVE_EXTRACT_SECURE_NODOTDOT 0x0200
#define ARCHIVE_EXTRACT_SPARSE 0x1000

struct archive *archive_read_new(void);
int archive_read_free(struct archive *);
int archive_read_open_fd(struct archive *, int, size_t);
int archive_read_next_header(struct archive *, struct archive_entry **);
int archive_read_extract2(struct archive *, struct archive_entry *, struct archive *);
int archive_read_support_format_7zip(struct archive *);
int archive_read_support_format_ar(struct archive *);
int archive_read_support_format_cab(struct archive *);
int archive_read_support_format_cpio(struct archive *);
int archive_read_support_format_empty(struct archive *);
int archive_read_support_format_lha(struct archive *);
int archive_read_support_format_rar(struct archive *);
int archive_read_support_format_rar5(struct archive *);
int archive_read_support_format_raw(struct archive *);
int archive_read_support_format_tar(struct archive *);
int archive_read_support_format_xar(struct archive *);
int archive_read_support_format_zip(struct archive *);
int archive_read_support_filter_bzip2(struct archive *);
int archive_read_support_filter_compress(struct archive *);
int archive_read_support_filter_gzip(struct archive *);
int archive_read_support_filter_lzip(struct archive *);
int archive_read_support_filter_lzma(struct archive *);
int archive_read_support_filter_xz(struct archive *);
int archive_filter_code(struct archive *, int);
int archive_format(struct archive *);
const char *archive_error_string(struct archive *);

struct archive *archive_write_disk_new(void);
int archive_write_disk_set_options(struct archive *, int);
int archive_write_close(struct archive *);
int archive_write_free(struct archive *);

mode_t archive_entry_filetype(struct archive_entry *);
mode_t archive_entry_perm(struct archive_entry *);
const char *archive_entry_pathname(struct archive_entry *);
const char *archive_entry_hardlink(struct archive_entry *);
const char *archive_entry_symlink(struct archive_entry *);
int archive_entry_is_encrypted(struct archive_entry *);
void archive_entry_set_pathname(struct archive_entry *, const char *);
void archive_entry_set_perm(struct archive_entry *, mode_t);
#endif

#endif
