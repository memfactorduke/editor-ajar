// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A command plus the project states needed for undo and deterministic redo.
public struct EditLogEntry: Equatable, Sendable {
    /// Command that produced `after` from `before`.
    public let command: EditCommand

    /// Project value before the command.
    public let before: Project

    /// Project value after the command.
    public let after: Project

    /// Creates an edit log entry.
    public init(command: EditCommand, before: Project, after: Project) {
        self.command = command
        self.before = before
        self.after = after
    }
}

/// Typed failures from edit history replay.
public enum EditHistoryError: Error, Equatable, Sendable {
    /// Replaying a redo command did not reproduce the recorded post-command project.
    case redoDiverged(command: EditCommand)

    /// A final-state command could not replace the previous undo entry deterministically.
    case coalescedReplayDiverged(command: EditCommand)

    /// The session was opened read-only (newer schema minor); edits are refused (FR-PROJ-005).
    case projectOpenedReadOnly(reason: AjarProjectReadOnlyReason)

    /// Platform media-state synchronization would make an existing undo entry non-replayable.
    case mediaReferenceReconciliationDiverged(command: EditCommand)
}

/// Unbounded per-session undo/redo history for immutable project values.
public struct EditHistory: Equatable, Sendable {
    /// Current project snapshot.
    public private(set) var currentProject: Project

    /// Whether this session may apply edits (ADR-0018 / FR-PROJ-005).
    public let openMode: AjarProjectOpenMode

    /// Commands that can be undone, oldest to newest.
    public private(set) var undoEntries: [EditLogEntry]

    /// Commands that can be redone, oldest to newest.
    public private(set) var redoEntries: [EditLogEntry]

    /// Number of available undo steps.
    public var undoCount: Int {
        undoEntries.count
    }

    /// Number of available redo steps.
    public var redoCount: Int {
        redoEntries.count
    }

    /// Command that would be undone next, if any.
    public var nextUndoCommand: EditCommand? {
        undoEntries.last?.command
    }

    /// Command that would be redone next, if any.
    public var nextRedoCommand: EditCommand? {
        redoEntries.last?.command
    }

    /// Creates an empty edit history at `project`.
    ///
    /// - Parameters:
    ///   - project: Initial project snapshot.
    ///   - openMode: From `AjarProjectLoadResult.openMode`. Read-only sessions refuse `apply` so
    ///     newer schema data cannot be stripped by edits (ADR-0018).
    public init(project: Project, openMode: AjarProjectOpenMode = .editable) {
        currentProject = project
        self.openMode = openMode
        undoEntries = []
        redoEntries = []
    }

    /// Creates history from a codec load result, preserving editable vs read-only mode.
    public init(loadResult: AjarProjectLoadResult) {
        currentProject = loadResult.project
        openMode = loadResult.openMode
        undoEntries = []
        redoEntries = []
    }

    /// Applies a command, appending one unbounded undo entry and clearing redo history.
    @discardableResult
    public mutating func apply(_ command: EditCommand) throws -> Project {
        if case .readOnly(let reason) = openMode {
            throw EditHistoryError.projectOpenedReadOnly(reason: reason)
        }

        let before = currentProject
        let after = try EditReducer.apply(command, to: before)
        undoEntries.append(EditLogEntry(command: command, before: before, after: after))
        redoEntries.removeAll(keepingCapacity: true)
        currentProject = after
        return after
    }

    /// Applies a final-state command while replacing the newest undo entry.
    ///
    /// Interactive controls use this after their first live update so a continuous gesture or
    /// text-input session remains one undo step while every intermediate value still passes
    /// through an `EditCommand`. The command must describe the complete final state: replaying it
    /// directly against the previous entry's `before` snapshot has to reproduce the new project.
    /// A divergent incremental command is rejected rather than creating an unsafe undo record.
    @discardableResult
    public mutating func applyCoalescingWithPrevious(_ command: EditCommand) throws -> Project {
        if case .readOnly(let reason) = openMode {
            throw EditHistoryError.projectOpenedReadOnly(reason: reason)
        }

        guard let previous = undoEntries.last else {
            return try apply(command)
        }

        let after = try EditReducer.apply(command, to: currentProject)
        let replayed = try EditReducer.apply(command, to: previous.before)
        guard replayed == after else {
            throw EditHistoryError.coalescedReplayDiverged(command: command)
        }

        if after == previous.before {
            undoEntries.removeLast()
        } else {
            undoEntries[undoEntries.count - 1] = EditLogEntry(
                command: command,
                before: previous.before,
                after: after
            )
        }
        redoEntries.removeAll(keepingCapacity: true)
        currentProject = after
        return after
    }

    /// Restores the previous project value, if an undo step exists.
    @discardableResult
    public mutating func undo() -> Project? {
        guard let entry = undoEntries.last else {
            return nil
        }

        undoEntries.removeLast()
        redoEntries.append(entry)
        currentProject = entry.before
        return currentProject
    }

    /// Replays the next redo command, if one exists.
    @discardableResult
    public mutating func redo() throws -> Project? {
        guard let entry = redoEntries.last else {
            return nil
        }

        let replayed = try EditReducer.apply(entry.command, to: currentProject)
        guard replayed == entry.after else {
            throw EditHistoryError.redoDiverged(command: entry.command)
        }

        redoEntries.removeLast()
        undoEntries.append(
            EditLogEntry(command: entry.command, before: currentProject, after: replayed)
        )
        currentProject = replayed
        return currentProject
    }

    /// Replaces the live project snapshot without creating an undo entry.
    ///
    /// Used for non-timeline session preferences (e.g. FR-MED-004 proxy playback toggle) that
    /// should persist with the document but not pollute the edit stack. Undo/redo entries keep
    /// their recorded project values; undoing after a preference flip may restore the prior
    /// preference value captured in that entry — acceptable for playback prefs.
    @discardableResult
    public mutating func replaceCurrentProjectPreservingHistory(_ project: Project) -> Project {
        currentProject = project
        return currentProject
    }

    /// Merges bookmark/offline resolution into every undo snapshot without creating an undo step.
    ///
    /// Only a reference still equal to `expected` apart from availability is replaced. A
    /// relink/consolidate edit that wins the race is therefore preserved, while unrelated timeline
    /// edits keep the newly resolved media state across undo and redo.
    @discardableResult
    public mutating func reconcileMediaReferences(
        expected: [MediaRef],
        resolved: [MediaRef]
    ) throws -> Project {
        let expectedByID = unambiguousMediaReferences(expected)
        let resolvedByID = unambiguousMediaReferences(resolved)

        func reconciledProject(_ project: Project) -> Project {
            Project(
                schemaVersion: project.schemaVersion,
                schemaMinor: project.schemaMinor,
                settings: project.settings,
                mediaPool: project.mediaPool.map { media in
                    guard
                        let expected = expectedByID[media.id],
                        referencesDifferOnlyByAvailability(media, expected),
                        let replacement = resolvedByID[media.id]
                    else {
                        return media
                    }
                    return replacement
                },
                sequences: project.sequences,
                looks: project.looks
            )
        }

        func reconciledEntry(_ entry: EditLogEntry) -> EditLogEntry {
            EditLogEntry(
                command: entry.command,
                before: reconciledProject(entry.before),
                after: reconciledProject(entry.after)
            )
        }

        let reconciledUndo = undoEntries.map(reconciledEntry)
        let reconciledRedo = redoEntries.map(reconciledEntry)
        for entry in reconciledUndo + reconciledRedo {
            let replayed: Project
            do {
                replayed = try EditReducer.apply(entry.command, to: entry.before)
            } catch {
                throw EditHistoryError.mediaReferenceReconciliationDiverged(
                    command: entry.command
                )
            }
            guard replayed == entry.after else {
                throw EditHistoryError.mediaReferenceReconciliationDiverged(
                    command: entry.command
                )
            }
        }

        currentProject = reconciledProject(currentProject)
        undoEntries = reconciledUndo
        redoEntries = reconciledRedo
        return currentProject
    }

    private func referencesDifferOnlyByAvailability(
        _ first: MediaRef,
        _ second: MediaRef
    ) -> Bool {
        first.id == second.id
            && first.sourceURL == second.sourceURL
            && first.bookmark == second.bookmark
            && first.contentHash == second.contentHash
            && first.metadata == second.metadata
    }

    private func unambiguousMediaReferences(_ references: [MediaRef]) -> [UUID: MediaRef] {
        var result: [UUID: MediaRef] = [:]
        var duplicates = Set<UUID>()
        for reference in references {
            if result[reference.id] == nil {
                result[reference.id] = reference
            } else {
                duplicates.insert(reference.id)
            }
        }
        for duplicate in duplicates {
            result[duplicate] = nil
        }
        return result
    }
}
