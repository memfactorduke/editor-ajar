// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore

extension OfflineAudioMixer {
    static func add(_ left: RationalTime, _ right: RationalTime) throws -> RationalTime {
        do {
            return try left.adding(right)
        } catch {
            throw AudioRenderError.timeArithmetic(String(describing: error))
        }
    }

    static func subtract(_ left: RationalTime, _ right: RationalTime) throws -> RationalTime {
        do {
            return try left.subtracting(right)
        } catch {
            throw AudioRenderError.timeArithmetic(String(describing: error))
        }
    }

    static func end(of range: TimeRange) throws -> RationalTime {
        do {
            return try range.end()
        } catch {
            throw AudioRenderError.timeArithmetic(String(describing: error))
        }
    }

    static func clipSourceTime(_ clip: Clip, at renderTime: RationalTime) throws -> RationalTime {
        do {
            return try clip.sourceTime(at: renderTime)
        } catch {
            throw AudioRenderError.timeArithmetic(String(describing: error))
        }
    }
}
