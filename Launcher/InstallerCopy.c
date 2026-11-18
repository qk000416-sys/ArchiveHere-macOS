#include "InstallerCopy.h"

#include <copyfile.h>
#include <errno.h>
#include <sys/types.h>

struct copy_context {
    void *object;
    ArchiveHereCopyProgress report;
};

static int report_copy(int event, int phase, copyfile_state_t state,
                       const char *source, const char *destination, void *pointer) {
    (void)destination;
    struct copy_context *context = pointer;
    if (event == COPYFILE_COPY_DATA && phase == COPYFILE_PROGRESS && source) {
        off_t copied = 0;
        if (copyfile_state_get(state, COPYFILE_STATE_COPIED, &copied) == 0) {
            context->report(context->object, source, copied);
        }
    }
    return COPYFILE_CONTINUE;
}

int archivehere_copy_bundle(const char *source, const char *destination,
                            void *object, ArchiveHereCopyProgress progress) {
    copyfile_state_t state = copyfile_state_alloc();
    if (!state) {
        return errno ? errno : ENOMEM;
    }
    struct copy_context context = {.object = object, .report = progress};
    int result = 0;
    if (copyfile_state_set(state, COPYFILE_STATE_STATUS_CB, report_copy) != 0
        || copyfile_state_set(state, COPYFILE_STATE_STATUS_CTX, &context) != 0
        || copyfile(source, destination, state,
                    COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_NOFOLLOW | COPYFILE_EXCL) != 0) {
        result = errno ? errno : EIO;
    }

    copyfile_state_free(state);
    return result;
}
