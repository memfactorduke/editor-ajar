// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

@testable import AjarExport

final class ExportJobStateMachineTests: XCTestCase {
    private struct LegalCase {
        let from: ExportJobState
        let event: ExportJobEvent
        let to: ExportJobState
    }

    private struct IllegalCase {
        let from: ExportJobState
        let event: ExportJobEvent
    }

    func testFREXP005LegalTransitionTableIsExhaustiveForDocumentedPairs() {
        let expected: [LegalCase] = [
            LegalCase(from: .pending, event: .start, to: .running),
            LegalCase(from: .pending, event: .cancel, to: .cancelled),
            LegalCase(from: .running, event: .pause, to: .pausedWillRestart),
            LegalCase(from: .running, event: .cancel, to: .cancelled),
            LegalCase(from: .running, event: .complete, to: .done),
            LegalCase(from: .running, event: .fail, to: .failed),
            LegalCase(from: .pausedWillRestart, event: .resume, to: .pending),
            LegalCase(from: .pausedWillRestart, event: .cancel, to: .cancelled)
        ]

        for entry in expected {
            let result = ExportJobStateMachine.apply(state: entry.from, event: entry.event)
            switch result {
            case .success(let next):
                XCTAssertEqual(next, entry.to, "\(entry.from) + \(entry.event)")
            case .failure(let error):
                XCTFail("expected \(entry.from)+\(entry.event)→\(entry.to), got \(error)")
            }
            XCTAssertTrue(
                ExportJobStateMachine.canApply(state: entry.from, event: entry.event)
            )
        }

        let tableCount = ExportJobStateMachine.legalTransitions.values.reduce(0) {
            $0 + $1.count
        }
        XCTAssertEqual(tableCount, expected.count)
    }

    func testFREXP005IllegalTransitionsAreRejected() {
        let illegal: [IllegalCase] = [
            IllegalCase(from: .pending, event: .pause),
            IllegalCase(from: .pending, event: .resume),
            IllegalCase(from: .pending, event: .complete),
            IllegalCase(from: .pending, event: .fail),
            IllegalCase(from: .running, event: .start),
            IllegalCase(from: .running, event: .resume),
            IllegalCase(from: .pausedWillRestart, event: .start),
            IllegalCase(from: .pausedWillRestart, event: .pause),
            IllegalCase(from: .pausedWillRestart, event: .complete),
            IllegalCase(from: .done, event: .cancel),
            IllegalCase(from: .failed, event: .resume),
            IllegalCase(from: .cancelled, event: .start)
        ]

        for entry in illegal {
            let result = ExportJobStateMachine.apply(state: entry.from, event: entry.event)
            guard case .failure(.illegalTransition(let reportedFrom, let reportedEvent)) = result
            else {
                XCTFail("expected illegal \(entry.from)+\(entry.event)")
                continue
            }
            XCTAssertEqual(reportedFrom, entry.from)
            XCTAssertEqual(reportedEvent, entry.event)
            XCTAssertFalse(
                ExportJobStateMachine.canApply(state: entry.from, event: entry.event)
            )
        }
    }

    func testFREXP005TerminalStates() {
        XCTAssertTrue(ExportJobStateMachine.isTerminal(.cancelled))
        XCTAssertTrue(ExportJobStateMachine.isTerminal(.failed))
        XCTAssertTrue(ExportJobStateMachine.isTerminal(.done))
        XCTAssertFalse(ExportJobStateMachine.isTerminal(.pending))
        XCTAssertFalse(ExportJobStateMachine.isTerminal(.running))
        XCTAssertFalse(ExportJobStateMachine.isTerminal(.pausedWillRestart))
    }

    func testFREXP005PauseSurfacesRestartContract() {
        // Documented honesty: pause does not mean mid-stream resume.
        let paused = ExportJobStateMachine.apply(state: .running, event: .pause)
        XCTAssertEqual(try paused.get(), .pausedWillRestart)
        let resumed = ExportJobStateMachine.apply(state: .pausedWillRestart, event: .resume)
        XCTAssertEqual(try resumed.get(), .pending)
    }
}
