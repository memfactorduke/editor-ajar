// SPDX-License-Identifier: GPL-3.0-or-later

import Darwin
import Foundation

enum ConsolidatePackageLockError: Error {
    case busy
    case unsafeLockFile(URL)
    case operationFailed(operation: String, code: Int32)
}

protocol ConsolidatePackageLock: AnyObject {
    func release()
}

protocol ConsolidatePackageLocking {
    func acquire(mediaDirectory: URL) throws -> any ConsolidatePackageLock
}

struct POSIXConsolidatePackageLocking: ConsolidatePackageLocking {
    func acquire(mediaDirectory: URL) throws -> any ConsolidatePackageLock {
        let lockURL = mediaDirectory.appendingPathComponent(".ajar-consolidation.lock")
        let descriptor = lockURL.path.withCString { path in
            Darwin.open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else {
            throw ConsolidatePackageLockError.operationFailed(
                operation: "open",
                code: errno
            )
        }

        var information = stat()
        guard fstat(descriptor, &information) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw ConsolidatePackageLockError.operationFailed(operation: "fstat", code: code)
        }
        guard information.st_mode & S_IFMT == S_IFREG else {
            Darwin.close(descriptor)
            throw ConsolidatePackageLockError.unsafeLockFile(lockURL)
        }

        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            if code == EWOULDBLOCK || code == EAGAIN {
                throw ConsolidatePackageLockError.busy
            }
            throw ConsolidatePackageLockError.operationFailed(operation: "flock", code: code)
        }
        return POSIXConsolidatePackageLock(descriptor: descriptor)
    }
}

private final class POSIXConsolidatePackageLock: ConsolidatePackageLock {
    private var descriptor: Int32

    init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    func release() {
        guard descriptor >= 0 else { return }
        _ = flock(descriptor, LOCK_UN)
        _ = Darwin.close(descriptor)
        descriptor = -1
    }

    deinit {
        release()
    }
}
