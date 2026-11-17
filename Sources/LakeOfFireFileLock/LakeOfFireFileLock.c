#include "LakeOfFireFileLock.h"
#include <sys/file.h>

int lake_reader_file_lock(int descriptor, int operation) {
    return flock(descriptor, operation);
}
