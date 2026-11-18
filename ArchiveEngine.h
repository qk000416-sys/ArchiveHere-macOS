#ifndef ARCHIVE_HERE_ENGINE_H
#define ARCHIVE_HERE_ENGINE_H

#include <stddef.h>

// Staging must be a private directory created for this extraction.
int extract_archive(const char *source, const char *staging,
                    const char *stream_name, char *error, size_t error_size);

int decode_stream(const char *source, const char *destination, const char *codec);

#endif
