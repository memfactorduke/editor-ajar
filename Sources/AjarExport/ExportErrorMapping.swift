// SPDX-License-Identifier: GPL-3.0-or-later

import AVFoundation
import Darwin
import Foundation

enum ExportErrorMapper {
    static func map(
        _ error: Error,
        destinationURL: URL
    ) -> ExportError {
        if let exportError = error as? ExportError {
            if case .diskFull = exportError {
                return .diskFull(destinationURL)
            }
            return exportError
        }
        if error is CancellationError {
            return .cancelled
        }
        if isDiskFull(error as NSError) {
            return .diskFull(destinationURL)
        }
        return .writerFailed(String(describing: error))
    }

    private static func isDiskFull(_ error: NSError) -> Bool {
        if error.domain == NSCocoaErrorDomain, error.code == NSFileWriteOutOfSpaceError {
            return true
        }
        if error.domain == NSPOSIXErrorDomain, error.code == Int(ENOSPC) {
            return true
        }
        if error.domain == AVFoundationErrorDomain,
            error.code == AVError.Code.diskFull.rawValue {
            return true
        }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            return isDiskFull(underlying)
        }
        return false
    }
}
