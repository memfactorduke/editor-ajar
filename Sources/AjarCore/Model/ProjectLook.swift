// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A named, project-persisted color-grade preset (FR-COL-007).
///
/// Grade animation is flattened to base values; grades and looks are static snapshots.
public struct ProjectLook: Codable, Equatable, Sendable {
    /// Stable look identity used by rename, delete, and apply commands.
    public let id: UUID

    /// User-visible look name. Project validation rejects blank and duplicate names.
    public let name: String

    /// Ordered color-grade nodes stored by the preset.
    ///
    /// Grade animation is flattened to base values; grades and looks are static snapshots.
    public let grade: ClipEffectStack

    /// Creates a project look.
    public init(id: UUID, name: String, grade: ClipEffectStack) {
        self.id = id
        self.name = name
        self.grade = grade
    }
}

/// Typed validation failures for a single project look.
public enum ProjectLookValidationError: Equatable, Sendable {
    /// The look name is empty or contains only whitespace and newlines.
    case blankName

    /// A saved look must contain at least one color-grade node.
    case emptyGrade

    /// The look contains a node outside the FR-COL-007 color-grade kind set.
    case nonColorGradeNode(nodeID: UUID, kind: ClipEffectKind)

    /// The stored grade violates an effect-stack invariant or parameter range.
    case invalidGrade(ClipEffectStackValidationError)
}

enum ProjectLookValidator {
    static func errors(for look: ProjectLook) -> [ProjectLookValidationError] {
        var errors: [ProjectLookValidationError] = []
        if normalizedName(look.name).isEmpty {
            errors.append(.blankName)
        }
        if look.grade.nodes.isEmpty {
            errors.append(.emptyGrade)
        }
        for node in look.grade.nodes where !node.kind.isColorGrade {
            errors.append(.nonColorGradeNode(nodeID: node.id, kind: node.kind))
        }
        errors.append(
            contentsOf: ClipEffectStackValidator.errors(for: look.grade).map {
                .invalidGrade($0)
            }
        )
        return errors
    }

    static func normalizedName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
