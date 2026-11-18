#include "ArchiveEngine.h"

#include <compression.h>
#include <fcntl.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static bool decode_apple_stream(FILE *input, FILE *output, compression_algorithm algorithm) {
    compression_stream stream;
    if (compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, algorithm) != COMPRESSION_STATUS_OK) {
        return false;
    }

    uint8_t input_buffer[64 * 1024];
    uint8_t output_buffer[64 * 1024];
    bool success = false;
    bool at_end = false;
    do {
        if (stream.src_size == 0 && !at_end) {
            stream.src_size = fread(input_buffer, 1, sizeof(input_buffer), input);
            stream.src_ptr = input_buffer;
            at_end = feof(input);
            if (ferror(input)) {
                break;
            }
        }
        stream.dst_ptr = output_buffer;
        stream.dst_size = sizeof(output_buffer);
        size_t available = stream.src_size;
        compression_status status = compression_stream_process(&stream,
            at_end ? COMPRESSION_STREAM_FINALIZE : 0);
        size_t written = sizeof(output_buffer) - stream.dst_size;
        if (status == COMPRESSION_STATUS_ERROR || fwrite(output_buffer, 1, written, output) != written) {
            break;
        }
        if (status == COMPRESSION_STATUS_END) {
            success = stream.src_size == 0 && fgetc(input) == EOF && !ferror(input);
            break;
        }
        if (written == 0 && stream.src_size == available) {
            break;
        }
    } while (true);

    compression_stream_destroy(&stream);
    return success;
}

static uint32_t little32(const uint8_t *bytes) {
    return (uint32_t)bytes[0] | (uint32_t)bytes[1] << 8 |
        (uint32_t)bytes[2] << 16 | (uint32_t)bytes[3] << 24;
}

static bool read32(FILE *file, uint32_t *value) {
    uint8_t bytes[4];
    if (fread(bytes, 1, sizeof(bytes), file) != sizeof(bytes)) {
        return false;
    }
    *value = little32(bytes);
    return true;
}

// XXH32 is used for the standard LZ4 frame checksums.
static const uint32_t prime1 = UINT32_C(2654435761);
static const uint32_t prime2 = UINT32_C(2246822519);
static const uint32_t prime3 = UINT32_C(3266489917);
static const uint32_t prime4 = UINT32_C(668265263);
static const uint32_t prime5 = UINT32_C(374761393);

typedef struct {
    uint32_t lanes[4];
    uint64_t size;
    size_t remainder_size;
    uint8_t remainder[16];
} Hash;

static Hash new_hash(void) {
    return (Hash){.lanes = {prime1 + prime2, prime2, 0, -prime1}};
}

static uint32_t rotate(uint32_t value, unsigned shift) {
    return (value << shift) | (value >> (32 - shift));
}

static void hash_chunk(Hash *hash, const uint8_t *bytes) {
    for (size_t i = 0; i < 4; i++) {
        hash->lanes[i] = rotate(hash->lanes[i] + little32(bytes + 4 * i) * prime2, 13) * prime1;
    }
}

static void hash_update(Hash *hash, const uint8_t *bytes, size_t size) {
    hash->size += size;
    if (hash->remainder_size) {
        size_t space = sizeof(hash->remainder) - hash->remainder_size;
        size_t copy = size < space ? size : space;
        memcpy(hash->remainder + hash->remainder_size, bytes, copy);
        bytes += copy;
        size -= copy;
        hash->remainder_size += copy;
        if (hash->remainder_size < sizeof(hash->remainder)) {
            return;
        }
        hash_chunk(hash, hash->remainder);
    }
    while (size >= 16) {
        hash_chunk(hash, bytes);
        bytes += 16;
        size -= 16;
    }
    memcpy(hash->remainder, bytes, size);
    hash->remainder_size = size;
}

static uint32_t hash_finish(const Hash *hash) {
    uint32_t value = prime5;
    if (hash->size >= 16) {
        value = rotate(hash->lanes[0], 1) + rotate(hash->lanes[1], 7) +
            rotate(hash->lanes[2], 12) + rotate(hash->lanes[3], 18);
    }
    value += (uint32_t)hash->size;
    size_t offset = 0;
    for (; hash->remainder_size - offset >= 4; offset += 4) {
        value = rotate(value + little32(hash->remainder + offset) * prime3, 17) * prime4;
    }
    for (; offset < hash->remainder_size; offset++) {
        value = rotate(value + (uint32_t)hash->remainder[offset] * prime5, 11) * prime1;
    }
    value = (value ^ (value >> 15)) * prime2;
    value = (value ^ (value >> 13)) * prime3;
    return value ^ (value >> 16);
}

static uint32_t hash_bytes(const uint8_t *bytes, size_t size) {
    Hash hash = new_hash();
    hash_update(&hash, bytes, size);
    return hash_finish(&hash);
}

static bool read_length(const uint8_t **cursor, const uint8_t *end, size_t *length) {
    if (*length != 15) {
        return true;
    }
    int extra;
    do {
        if (*cursor == end) {
            return false;
        }
        extra = *(*cursor)++;
        *length += (size_t)extra;
    } while (extra == 255);
    return true;
}

static bool decode_lz4_block(const uint8_t *bytes, size_t size, uint8_t *decoded,
                             size_t history, size_t capacity, size_t *written) {
    const uint8_t *end = bytes + size;
    size_t position = history;
    size_t limit = history + capacity;
    while (bytes < end) {
        uint8_t token = *bytes++;
        size_t literals = token >> 4;
        if (!read_length(&bytes, end, &literals) || literals > (size_t)(end - bytes)
            || literals > limit - position) {
            return false;
        }
        memcpy(decoded + position, bytes, literals);
        position += literals;
        bytes += literals;
        if (bytes == end) {
            *written = position - history;
            return true;
        }
        if (end - bytes < 2) {
            return false;
        }
        size_t distance = bytes[0] | ((size_t)bytes[1] << 8);
        bytes += 2;
        size_t match = token & 15;
        if (!read_length(&bytes, end, &match) || !distance || distance > position
            || match + 4 > limit - position) {
            return false;
        }
        for (size_t i = 0; i < match + 4; i++, position++) {
            decoded[position] = decoded[position - distance];
        }
    }
    return false;
}

static bool decode_lz4_frame(FILE *input, FILE *output) {
    uint8_t header[10];
    if (fread(header, 1, 2, input) != 2) {
        return false;
    }
    uint8_t flags = header[0];
    unsigned size_code = (header[1] >> 4) & 7;
    if ((flags & 0xc3) != 0x40 || (header[1] & 0x8f) != 0 || size_code < 4) {
        return false;
    }
    size_t header_size = flags & 8 ? 10 : 2;
    if (header_size > 2 && fread(header + 2, 1, 8, input) != 8) {
        return false;
    }
    if (fgetc(input) != (int)((hash_bytes(header, header_size) >> 8) & 255)) {
        return false;
    }

    bool success = false;
    const size_t max_history = 65536;
    size_t block_size = (size_t)1 << (8 + 2 * size_code);
    uint8_t *bytes = malloc(block_size);
    uint8_t *decoded = malloc(block_size + max_history);
    size_t history = 0;
    uint64_t total = 0;
    Hash content = new_hash();
    uint32_t block;

    while (bytes && decoded && read32(input, &block)) {
        if (block == 0) {
            uint32_t expected;
            success = !(flags & 4) || (read32(input, &expected) && hash_finish(&content) == expected);
            if (flags & 8) {
                uint64_t expected_size = little32(header + 2) | ((uint64_t)little32(header + 6) << 32);
                success = success && expected_size == total;
            }
            break;
        }
        size_t size = block & UINT32_C(0x7fffffff);
        if (size > block_size || fread(bytes, 1, size, input) != size) {
            break;
        }
        if (flags & 16) {
            uint32_t expected;
            if (!read32(input, &expected) || hash_bytes(bytes, size) != expected) {
                break;
            }
        }
        size_t written = size;
        if (block >> 31) {
            memcpy(decoded + history, bytes, size);
        } else if (!decode_lz4_block(bytes, size, decoded, history, block_size, &written)) {
            break;
        }
        if (fwrite(decoded + history, 1, written, output) != written) {
            break;
        }
        if (flags & 4) {
            hash_update(&content, decoded + history, written);
        }
        total += written;
        if (!(flags & 32)) {
            size_t available = history + written;
            history = available < max_history ? available : max_history;
            memmove(decoded, decoded + available - history, history);
        }
    }

    free(bytes);
    free(decoded);
    return success;
}

static bool decode_lz4(FILE *input, FILE *output) {
    bool decoded = false;
    for (;;) {
        int first = fgetc(input);
        if (first == EOF) {
            return decoded && !ferror(input);
        }
        uint8_t magic[4] = {(uint8_t)first};
        if (fread(magic + 1, 1, 3, input) != 3) {
            return false;
        }
        uint32_t value = little32(magic);
        if ((value & UINT32_C(0xfffffff0)) == UINT32_C(0x184d2a50)) {
            uint32_t remaining;
            uint8_t buffer[4096];
            if (!read32(input, &remaining)) {
                return false;
            }
            while (remaining) {
                size_t count = remaining < sizeof(buffer) ? remaining : sizeof(buffer);
                if (fread(buffer, 1, count, input) != count) {
                    return false;
                }
                remaining -= (uint32_t)count;
            }
        } else if (value == UINT32_C(0x184d2204) && decode_lz4_frame(input, output)) {
            decoded = true;
        } else {
            return false;
        }
    }
}

int decode_stream(const char *source, const char *destination, const char *codec) {
    int fd = open(source, O_RDONLY | O_CLOEXEC | O_NONBLOCK);
    struct stat info;
    if (fd < 0) {
        return -1;
    }
    FILE *input = fstat(fd, &info) == 0 && S_ISREG(info.st_mode) ? fdopen(fd, "rb") : NULL;
    if (!input) {
        close(fd);
        return -1;
    }
    int output_fd = open(destination, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0644);
    FILE *output = output_fd < 0 ? NULL : fdopen(output_fd, "wb");
    if (!output) {
        if (output_fd >= 0) {
            close(output_fd);
        }
        fclose(input);
        return -1;
    }

    bool success;
    if (strcmp(codec, "lz4") == 0) {
        success = decode_lz4(input, output);
    } else {
        compression_algorithm algorithm = strcmp(codec, "br") == 0 ? COMPRESSION_BROTLI : COMPRESSION_LZFSE;
        success = decode_apple_stream(input, output, algorithm);
    }
    success = fclose(output) == 0 && success;
    fclose(input);
    return success ? 0 : -1;
}
