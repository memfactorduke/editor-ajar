// SPDX-License-Identifier: GPL-3.0-or-later

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
}

/// Unbounded per-session undo/redo history for immutable project values.
public struct EditHistory: Equatable, Sendable {
    /// Current project snapshot.
    public private(set) var currentProject: Project

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

    /// Creates an empty edit history at `project`.
    public init(project: Project) {
        currentProject = project
        undoEntries = []
        redoEntries = []
    }

    /// Applies a command, appending one unbounded undo entry and clearing redo history.
    @discardableResult
    public mutating func apply(_ command: EditCommand) throws -> Project {
        let before = currentProject
        let after = try EditReducer.apply(command, to: before)
        undoEntries.append(EditLogEntry(command: command, before: before, after: after))
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
}
