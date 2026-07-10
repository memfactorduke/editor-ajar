// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation
import Metal
import XCTest

@testable import AjarExport

/// FR-EXP-007 proxy exclusion hook (FR-MED-004 / #217 can extend the resolver).
final class ExportSourceSelectionTests: XCTestCase {
    func testFREXP007ProductionPolicyAlwaysResolvesOriginal() {
        let policy = ExportSourceSelectionPolicy.alwaysOriginal
        let mediaID = UUID()
        XCTAssertEqual(policy.resolvedTier(for: mediaID), .original)
        XCTAssertEqual(policy.defaultTier, .original)
    }

    func testFREXP007ExportSessionRecordsOriginalSourceTiers() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal device unavailable on this runner")
        }

        let fixture = try ExportGoldenFixture(frameCount: 4, includeAudio: true)
        defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }

        let settings = try fixture.movieSettings(
            container: .mov,
            codec: .proRes422,
            audioCodec: .linearPCM
        )
        let destinationURL = fixture.directoryURL.appendingPathComponent("audit.mov")
        let exported = try await fixture.exportMovie(to: destinationURL, settings: settings)

        XCTAssertEqual(exported.session.sourceSelectionPolicy, .alwaysOriginal)
        let records = exported.session.sourceSelectionRecords
        XCTAssertFalse(records.isEmpty, "expected media-pool audit rows for audio media id")
        XCTAssertEqual(records.count, 4, "one media id × four frames")
        XCTAssertTrue(records.allSatisfy { $0.tier == .original })
        XCTAssertEqual(Set(records.map(\.frameIndex)), Set(0..<4))
    }

    func testFREXP007InjectedProxyPolicyIsVisibleInAuditForMED004Extension() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal device unavailable on this runner")
        }

        // Proves the hook records policy output so #217 can extend resolvedTier without a new path.
        let fixture = try ExportGoldenFixture(frameCount: 2, includeAudio: true)
        defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }

        let settings = try fixture.movieSettings(
            container: .mov,
            codec: .proRes422,
            audioCodec: .linearPCM
        )
        let destinationURL = fixture.directoryURL.appendingPathComponent("proxy-audit.mov")
        let exported = try await fixture.exportMovie(
            to: destinationURL,
            settings: settings,
            sourceSelectionPolicy: ExportSourceSelectionPolicy(defaultTier: .proxy)
        )

        XCTAssertEqual(exported.session.sourceSelectionPolicy.defaultTier, .proxy)
        XCTAssertFalse(exported.session.sourceSelectionRecords.isEmpty)
        XCTAssertTrue(exported.session.sourceSelectionRecords.allSatisfy { $0.tier == .proxy })
    }
}
