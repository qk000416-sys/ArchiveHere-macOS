#ifndef ARCHIVE_HERE_INSTALLER_COPY_H
#define ARCHIVE_HERE_INSTALLER_COPY_H
#include <stdint.h>

typedef void (*ArchiveHereCopyProgress)(void *, const char *, int64_t);

// Preserves the bundle's file modes, attributes and signed resources.
int archivehere_copy_bundle(const char *source, const char *destination,
                            void *context, ArchiveHereCopyProgress progress);

#endif
