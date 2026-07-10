// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Typed ADR-0016 §5 video transition pair and source-handle validation errors (FR-FX-001).
///
/// Taxonomy mirrors ADR-0015 §5 audio crossfade errors so the edit matrix and tests share
/// one vocabulary shape.
public enum VideoTransitionValidationError: Equatable, Sendable {
    /// Transition metadata points back at the owning clip.
    case transitionPartnerMatchesClip(edge: ClipVideoTransitionEdge, clipID: UUID)

    /// Transition metadata points at no clip on the owning track.
    case transitionPartnerMissing(edge: ClipVideoTransitionEdge, clipID: UUID, partnerClipID: UUID)

    /// Transition metadata points at a clip that does not abut the owning edge.
    case transitionPartnerNotAdjacent(
        edge: ClipVideoTransitionEdge,
        clipID: UUID,
        partnerClipID: UUID
    )

    /// Transition partners are separated by one or more gap items.
    case transitionSeparatedByGap(edge: ClipVideoTransitionEdge, clipID: UUID, partnerClipID: UUID)

    /// A transition record sits on the wrong edge for its partner's position.
    case transitionDirectionInvalid(
        edge: ClipVideoTransitionEdge,
        clipID: UUID,
        partnerClipID: UUID
    )

    /// The partner clip is missing the mirroring transition record.
    case transitionMirrorMissing(edge: ClipVideoTransitionEdge, clipID: UUID, partnerClipID: UUID)

    /// The two transition records disagree on kind, duration, or parameters.
    case transitionPairMismatched(edge: ClipVideoTransitionEdge, clipID: UUID, partnerClipID: UUID)

    /// A clip with an FR-SPD-002 time-remap curve carries a transition edge.
    case transitionUnsupportedWithTimeRemap(edge: ClipVideoTransitionEdge, clipID: UUID)

    /// The outgoing tail's effective read window leaves the declared media bounds.
    case transitionExceedsSourceHandle(edge: ClipVideoTransitionEdge, clipID: UUID, mediaID: UUID)

    /// Push/slide used a diagonal direction (wipe-only in v1).
    case transitionDirectionUnsupportedForKind(
        edge: ClipVideoTransitionEdge,
        clipID: UUID,
        kind: ClipVideoTransitionKind,
        direction: ClipVideoTransitionDirection
    )

    /// Exact time arithmetic failed while validating a transition.
    case timeArithmetic(clipID: UUID, detail: String)

    /// The clip owning the invalid transition record.
    public var clipID: UUID {
        switch self {
        case .transitionPartnerMatchesClip(_, let clipID),
            .transitionPartnerMissing(_, let clipID, _),
            .transitionPartnerNotAdjacent(_, let clipID, _),
            .transitionSeparatedByGap(_, let clipID, _),
            .transitionDirectionInvalid(_, let clipID, _),
            .transitionMirrorMissing(_, let clipID, _),
            .transitionPairMismatched(_, let clipID, _),
            .transitionUnsupportedWithTimeRemap(_, let clipID),
            .transitionExceedsSourceHandle(_, let clipID, _),
            .transitionDirectionUnsupportedForKind(_, let clipID, _, _),
            .timeArithmetic(let clipID, _):
            return clipID
        }
    }
}

/// Validates the ADR-0016 §5 transition pair taxonomy and source-handle rule over one
/// track's items (FR-FX-001).
///
/// Exactly one transition per cut, owned by the outgoing clip's trailing record with the
/// incoming clip's leading record as a non-rendering mirror. Handle checks run only when
/// the owning media's declared duration is known.
public enum ClipVideoTransitionValidator {
    /// Returns all transition validation errors for one track's items in item order.
    public static func errors(
        in items: [TimelineItem],
        mediaDurationsByID: [UUID: RationalTime] = [:]
    ) -> [VideoTransitionValidationError] {
        var errors: [VideoTransitionValidationError] = []
        for index in items.indices {
            guard case .clip(let clip) = items[index] else {
                continue
            }
            let context = RecordContext(
                clip: clip,
                index: index,
                items: items,
                mediaDurationsByID: mediaDurationsByID
            )
            appendErrors(
                record: clip.leadingTransition,
                edge: .leading,
                context: context,
                to: &errors
            )
            appendErrors(
                record: clip.trailingTransition,
                edge: .trailing,
                context: context,
                to: &errors
            )
        }
        return errors
    }
}

private extension ClipVideoTransitionValidator {
    struct RecordContext {
        let clip: Clip
        let index: Array<TimelineItem>.Index
        let items: [TimelineItem]
        let mediaDurationsByID: [UUID: RationalTime]
    }

    static func appendErrors(
        record: ClipVideoTransition?,
        edge: ClipVideoTransitionEdge,
        context: RecordContext,
        to errors: inout [VideoTransitionValidationError]
    ) {
        guard let record else {
            return
        }
        if record.partnerClipID == context.clip.id {
            errors.append(.transitionPartnerMatchesClip(edge: edge, clipID: context.clip.id))
            return
        }
        appendRecordShapeErrors(record: record, edge: edge, clip: context.clip, to: &errors)
        appendPairErrors(record: record, edge: edge, context: context, to: &errors)
        appendHandleErrors(record: record, edge: edge, context: context, to: &errors)
    }

    static func appendRecordShapeErrors(
        record: ClipVideoTransition,
        edge: ClipVideoTransitionEdge,
        clip: Clip,
        to errors: inout [VideoTransitionValidationError]
    ) {
        if clip.timeRemap != nil {
            errors.append(.transitionUnsupportedWithTimeRemap(edge: edge, clipID: clip.id))
        }
        switch record.kind {
        case .push, .slide:
            if record.direction.isDiagonal {
                errors.append(
                    .transitionDirectionUnsupportedForKind(
                        edge: edge,
                        clipID: clip.id,
                        kind: record.kind,
                        direction: record.direction
                    )
                )
            }
        case .crossDissolve, .dipToColor, .fade, .wipe, .zoom:
            break
        }
    }

    static func appendPairErrors(
        record: ClipVideoTransition,
        edge: ClipVideoTransitionEdge,
        context: RecordContext,
        to errors: inout [VideoTransitionValidationError]
    ) {
        let clip = context.clip
        let items = context.items
        if let neighbor = nearestClip(from: context.index, towardPartnerOf: edge, in: items),
            neighbor.clip.id == record.partnerClipID {
            if neighbor.skippedGapCount > 0 {
                errors.append(
                    .transitionSeparatedByGap(
                        edge: edge,
                        clipID: clip.id,
                        partnerClipID: record.partnerClipID
                    )
                )
            } else {
                appendAbuttingPartnerErrors(
                    record: record,
                    edge: edge,
                    clip: clip,
                    partner: neighbor.clip,
                    to: &errors
                )
            }
            return
        }
        if let opposite = nearestClip(from: context.index, awayFromPartnerOf: edge, in: items),
            opposite.clip.id == record.partnerClipID {
            errors.append(
                .transitionDirectionInvalid(
                    edge: edge,
                    clipID: clip.id,
                    partnerClipID: record.partnerClipID
                )
            )
            return
        }
        if containsClip(record.partnerClipID, in: context.items) {
            errors.append(
                .transitionPartnerNotAdjacent(
                    edge: edge,
                    clipID: clip.id,
                    partnerClipID: record.partnerClipID
                )
            )
            return
        }
        errors.append(
            .transitionPartnerMissing(
                edge: edge,
                clipID: clip.id,
                partnerClipID: record.partnerClipID
            )
        )
    }

    static func appendAbuttingPartnerErrors(
        record: ClipVideoTransition,
        edge: ClipVideoTransitionEdge,
        clip: Clip,
        partner: Clip,
        to errors: inout [VideoTransitionValidationError]
    ) {
        switch touches(clip, partner: partner, edge: edge) {
        case .arithmeticFailure(let detail):
            errors.append(.timeArithmetic(clipID: clip.id, detail: detail))
            return
        case .notTouching:
            errors.append(
                .transitionPartnerNotAdjacent(
                    edge: edge,
                    clipID: clip.id,
                    partnerClipID: record.partnerClipID
                )
            )
            return
        case .touching:
            break
        }

        let mirror = mirrorRecord(on: partner, forOwningEdge: edge)
        guard let mirror, mirror.partnerClipID == clip.id else {
            errors.append(
                .transitionMirrorMissing(
                    edge: edge,
                    clipID: clip.id,
                    partnerClipID: record.partnerClipID
                )
            )
            return
        }
        if !mirror.agrees(with: record) {
            errors.append(
                .transitionPairMismatched(
                    edge: edge,
                    clipID: clip.id,
                    partnerClipID: record.partnerClipID
                )
            )
        }
    }

    static func mirrorRecord(
        on partner: Clip,
        forOwningEdge edge: ClipVideoTransitionEdge
    ) -> ClipVideoTransition? {
        switch edge {
        case .trailing:
            return partner.leadingTransition
        case .leading:
            return partner.trailingTransition
        }
    }

    enum TouchResult {
        case touching
        case notTouching
        case arithmeticFailure(String)
    }

    static func touches(
        _ clip: Clip,
        partner: Clip,
        edge: ClipVideoTransitionEdge
    ) -> TouchResult {
        do {
            switch edge {
            case .leading:
                return try partner.timelineRange.end() == clip.timelineRange.start
                    ? .touching : .notTouching
            case .trailing:
                return try clip.timelineRange.end() == partner.timelineRange.start
                    ? .touching : .notTouching
            }
        } catch {
            return .arithmeticFailure(String(describing: error))
        }
    }

    static func appendHandleErrors(
        record: ClipVideoTransition,
        edge: ClipVideoTransitionEdge,
        context: RecordContext,
        to errors: inout [VideoTransitionValidationError]
    ) {
        // ADR-0015 §3 / ADR-0016 §5: only the outgoing trailing edge extends its read window.
        let clip = context.clip
        guard edge == .trailing, record.duration > .zero else {
            return
        }
        guard !clip.freezeFrame, clip.timeRemap == nil else {
            return
        }
        guard case .media(let mediaID) = clip.source else {
            return
        }
        guard let mediaDuration = context.mediaDurationsByID[mediaID] else {
            return
        }
        do {
            let tailSourceDuration = try Clip.sourceDuration(
                forTimelineDuration: record.duration,
                speed: clip.speed
            )
            if try tailWindowLeavesMedia(
                clip: clip,
                tailSourceDuration: tailSourceDuration,
                mediaDuration: mediaDuration
            ) {
                errors.append(
                    .transitionExceedsSourceHandle(edge: edge, clipID: clip.id, mediaID: mediaID)
                )
            }
        } catch {
            errors.append(
                .timeArithmetic(clipID: clip.id, detail: String(describing: error))
            )
        }
    }

    static func tailWindowLeavesMedia(
        clip: Clip,
        tailSourceDuration: RationalTime,
        mediaDuration: RationalTime
    ) throws -> Bool {
        if clip.reverse {
            return clip.sourceRange.start < tailSourceDuration
        }
        let sourceEnd = try clip.sourceRange.end()
        let requiredEnd = try sourceEnd.adding(tailSourceDuration)
        return requiredEnd > mediaDuration
    }

    static func nearestClip(
        from index: Array<TimelineItem>.Index,
        towardPartnerOf edge: ClipVideoTransitionEdge,
        in items: [TimelineItem]
    ) -> (clip: Clip, skippedGapCount: Int)? {
        switch edge {
        case .leading:
            return nearestClip(from: index, direction: -1, in: items)
        case .trailing:
            return nearestClip(from: index, direction: 1, in: items)
        }
    }

    static func nearestClip(
        from index: Array<TimelineItem>.Index,
        awayFromPartnerOf edge: ClipVideoTransitionEdge,
        in items: [TimelineItem]
    ) -> (clip: Clip, skippedGapCount: Int)? {
        switch edge {
        case .leading:
            return nearestClip(from: index, direction: 1, in: items)
        case .trailing:
            return nearestClip(from: index, direction: -1, in: items)
        }
    }

    static func nearestClip(
        from index: Array<TimelineItem>.Index,
        direction: Int,
        in items: [TimelineItem]
    ) -> (clip: Clip, skippedGapCount: Int)? {
        var skippedGapCount = 0
        var cursor = index + direction
        while cursor >= items.startIndex && cursor < items.endIndex {
            switch items[cursor] {
            case .clip(let clip):
                return (clip, skippedGapCount)
            case .gap:
                skippedGapCount += 1
                cursor += direction
            case .transition:
                return nil
            }
        }
        return nil
    }

    static func containsClip(_ clipID: UUID, in items: [TimelineItem]) -> Bool {
        items.contains { item in
            if case .clip(let clip) = item {
                return clip.id == clipID
            }
            return false
        }
    }
}
