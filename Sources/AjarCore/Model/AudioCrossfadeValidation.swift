// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Typed ADR-0015 crossfade pair and source-handle validation errors (FR-AUD-002).
public enum AudioCrossfadeValidationError: Equatable, Sendable {
    /// Crossfade metadata points back at the owning clip.
    case crossfadePartnerMatchesClip(edge: ClipAudioFadeEdge, clipID: UUID)

    /// Crossfade metadata points at no clip on the owning track.
    case crossfadePartnerMissing(edge: ClipAudioFadeEdge, clipID: UUID, partnerClipID: UUID)

    /// Crossfade metadata points at a clip that does not abut the owning edge.
    case crossfadePartnerNotAdjacent(edge: ClipAudioFadeEdge, clipID: UUID, partnerClipID: UUID)

    /// Crossfade partners are separated by one or more gap items (ADR-0015 §5).
    case crossfadeSeparatedByGap(edge: ClipAudioFadeEdge, clipID: UUID, partnerClipID: UUID)

    /// A crossfade record sits on the wrong edge for its partner's position (ADR-0015 §5).
    case crossfadeDirectionInvalid(edge: ClipAudioFadeEdge, clipID: UUID, partnerClipID: UUID)

    /// The partner clip is missing the mirroring crossfade record (ADR-0015 §5).
    case crossfadeMirrorMissing(edge: ClipAudioFadeEdge, clipID: UUID, partnerClipID: UUID)

    /// The two crossfade records disagree on duration or curve (ADR-0015 §5).
    case crossfadePairMismatched(edge: ClipAudioFadeEdge, clipID: UUID, partnerClipID: UUID)

    /// A same-edge fade and crossfade were both stored (ADR-0015 §6).
    case crossfadeConflictsWithFade(edge: ClipAudioFadeEdge, clipID: UUID)

    /// A crossfade edge uses a fade-to-silence-only curve (ADR-0015 §4).
    case crossfadeCurveUnsupported(
        edge: ClipAudioFadeEdge,
        clipID: UUID,
        curve: ClipAudioFadeCurve
    )

    /// A clip with an FR-SPD-002 time-remap curve carries a crossfade edge (ADR-0015 §2).
    case crossfadeUnsupportedWithTimeRemap(edge: ClipAudioFadeEdge, clipID: UUID)

    /// The outgoing tail's effective read window leaves the declared media bounds (ADR-0015 §3).
    case crossfadeExceedsSourceHandle(edge: ClipAudioFadeEdge, clipID: UUID, mediaID: UUID)

    /// Exact time arithmetic failed while validating a crossfade.
    case timeArithmetic(clipID: UUID, detail: String)

    /// The clip owning the invalid crossfade record.
    public var clipID: UUID {
        switch self {
        case .crossfadePartnerMatchesClip(_, let clipID),
            .crossfadePartnerMissing(_, let clipID, _),
            .crossfadePartnerNotAdjacent(_, let clipID, _),
            .crossfadeSeparatedByGap(_, let clipID, _),
            .crossfadeDirectionInvalid(_, let clipID, _),
            .crossfadeMirrorMissing(_, let clipID, _),
            .crossfadePairMismatched(_, let clipID, _),
            .crossfadeConflictsWithFade(_, let clipID),
            .crossfadeCurveUnsupported(_, let clipID, _),
            .crossfadeUnsupportedWithTimeRemap(_, let clipID),
            .crossfadeExceedsSourceHandle(_, let clipID, _),
            .timeArithmetic(let clipID, _):
            return clipID
        }
    }
}

/// Validates the ADR-0015 crossfade pair taxonomy and source-handle rule over one
/// track's items (FR-AUD-002).
///
/// The taxonomy is model-level: exactly one transition per cut, owned by the outgoing
/// clip's trailing record with the incoming clip's leading record as a non-rendering
/// mirror. Handle checks run only when the owning media's declared duration is known;
/// callers without media metadata (for example, render-time sequence validation) pass
/// an empty duration map and get the pure pair taxonomy.
public enum ClipAudioCrossfadeValidator {
    /// Curves ADR-0015 §4 permits on crossfade edges.
    static let supportedCrossfadeCurves: Set<ClipAudioFadeCurve> = [.linear, .equalPower]

    /// Returns all crossfade validation errors for one track's items in item order.
    public static func errors(
        in items: [TimelineItem],
        mediaDurationsByID: [UUID: RationalTime] = [:]
    ) -> [AudioCrossfadeValidationError] {
        var errors: [AudioCrossfadeValidationError] = []
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
                record: clip.audioMix.leadingCrossfade,
                edge: .leadingCrossfade,
                context: context,
                to: &errors
            )
            appendErrors(
                record: clip.audioMix.trailingCrossfade,
                edge: .trailingCrossfade,
                context: context,
                to: &errors
            )
        }
        return errors
    }
}

private extension ClipAudioCrossfadeValidator {
    struct RecordContext {
        let clip: Clip
        let index: Array<TimelineItem>.Index
        let items: [TimelineItem]
        let mediaDurationsByID: [UUID: RationalTime]
    }

    static func appendErrors(
        record: ClipAudioCrossfade?,
        edge: ClipAudioFadeEdge,
        context: RecordContext,
        to errors: inout [AudioCrossfadeValidationError]
    ) {
        guard let record else {
            return
        }
        if record.partnerClipID == context.clip.id {
            errors.append(.crossfadePartnerMatchesClip(edge: edge, clipID: context.clip.id))
            return
        }
        appendRecordShapeErrors(record: record, edge: edge, clip: context.clip, to: &errors)
        appendPairErrors(record: record, edge: edge, context: context, to: &errors)
        appendHandleErrors(record: record, edge: edge, context: context, to: &errors)
    }

    static func appendRecordShapeErrors(
        record: ClipAudioCrossfade,
        edge: ClipAudioFadeEdge,
        clip: Clip,
        to errors: inout [AudioCrossfadeValidationError]
    ) {
        if !supportedCrossfadeCurves.contains(record.curve) {
            errors.append(
                .crossfadeCurveUnsupported(edge: edge, clipID: clip.id, curve: record.curve)
            )
        }
        if conflictingFadeDuration(for: edge, in: clip.audioMix) > .zero {
            errors.append(.crossfadeConflictsWithFade(edge: edge, clipID: clip.id))
        }
        if clip.timeRemap != nil {
            errors.append(.crossfadeUnsupportedWithTimeRemap(edge: edge, clipID: clip.id))
        }
    }

    static func conflictingFadeDuration(
        for edge: ClipAudioFadeEdge,
        in mix: ClipAudioMix
    ) -> RationalTime {
        switch edge {
        case .leadingCrossfade:
            return mix.fadeIn.duration
        case .trailingCrossfade:
            return mix.fadeOut.duration
        case .fadeIn, .fadeOut:
            return .zero
        }
    }

    static func appendPairErrors(
        record: ClipAudioCrossfade,
        edge: ClipAudioFadeEdge,
        context: RecordContext,
        to errors: inout [AudioCrossfadeValidationError]
    ) {
        let clip = context.clip
        let items = context.items
        if let neighbor = nearestClip(from: context.index, towardPartnerOf: edge, in: items),
            neighbor.clip.id == record.partnerClipID {
            if neighbor.skippedGapCount > 0 {
                errors.append(
                    .crossfadeSeparatedByGap(
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
                .crossfadeDirectionInvalid(
                    edge: edge,
                    clipID: clip.id,
                    partnerClipID: record.partnerClipID
                )
            )
            return
        }
        if containsClip(record.partnerClipID, in: context.items) {
            errors.append(
                .crossfadePartnerNotAdjacent(
                    edge: edge,
                    clipID: clip.id,
                    partnerClipID: record.partnerClipID
                )
            )
            return
        }
        errors.append(
            .crossfadePartnerMissing(
                edge: edge,
                clipID: clip.id,
                partnerClipID: record.partnerClipID
            )
        )
    }

    static func appendAbuttingPartnerErrors(
        record: ClipAudioCrossfade,
        edge: ClipAudioFadeEdge,
        clip: Clip,
        partner: Clip,
        to errors: inout [AudioCrossfadeValidationError]
    ) {
        switch touches(clip, partner: partner, edge: edge) {
        case .arithmeticFailure(let detail):
            errors.append(.timeArithmetic(clipID: clip.id, detail: detail))
            return
        case .notTouching:
            errors.append(
                .crossfadePartnerNotAdjacent(
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
                .crossfadeMirrorMissing(
                    edge: edge,
                    clipID: clip.id,
                    partnerClipID: record.partnerClipID
                )
            )
            return
        }
        if mirror.duration != record.duration || mirror.curve != record.curve {
            errors.append(
                .crossfadePairMismatched(
                    edge: edge,
                    clipID: clip.id,
                    partnerClipID: record.partnerClipID
                )
            )
        }
    }

    static func mirrorRecord(
        on partner: Clip,
        forOwningEdge edge: ClipAudioFadeEdge
    ) -> ClipAudioCrossfade? {
        switch edge {
        case .trailingCrossfade:
            return partner.audioMix.leadingCrossfade
        case .leadingCrossfade:
            return partner.audioMix.trailingCrossfade
        case .fadeIn, .fadeOut:
            return nil
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
        edge: ClipAudioFadeEdge
    ) -> TouchResult {
        do {
            switch edge {
            case .leadingCrossfade:
                return try partner.timelineRange.end() == clip.timelineRange.start
                    ? .touching : .notTouching
            case .trailingCrossfade:
                return try clip.timelineRange.end() == partner.timelineRange.start
                    ? .touching : .notTouching
            case .fadeIn, .fadeOut:
                return .notTouching
            }
        } catch {
            return .arithmeticFailure(String(describing: error))
        }
    }

    static func appendHandleErrors(
        record: ClipAudioCrossfade,
        edge: ClipAudioFadeEdge,
        context: RecordContext,
        to errors: inout [AudioCrossfadeValidationError]
    ) {
        // ADR-0015 §3: only the outgoing clip's trailing edge extends its read window;
        // the mirror-side leading record never needs media beyond its source range.
        let clip = context.clip
        guard edge == .trailingCrossfade, record.duration > .zero else {
            return
        }
        // Freeze frames hold one frame and need no tail media; time-remap clips were
        // already rejected for crossfade edges, so their curve is never extrapolated.
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
                    .crossfadeExceedsSourceHandle(edge: edge, clipID: clip.id, mediaID: mediaID)
                )
            }
        } catch {
            errors.append(
                .timeArithmetic(clipID: clip.id, detail: String(describing: error))
            )
        }
    }

    /// Throws on rational-time arithmetic failure so the caller reports it as
    /// `timeArithmetic` rather than misdiagnosing a handle shortfall.
    static func tailWindowLeavesMedia(
        clip: Clip,
        tailSourceDuration: RationalTime,
        mediaDuration: RationalTime
    ) throws -> Bool {
        if clip.reverse {
            // The reversed tail keeps reading backward past `sourceRange.start`.
            return clip.sourceRange.start < tailSourceDuration
        }
        let sourceEnd = try clip.sourceRange.end()
        let requiredEnd = try sourceEnd.adding(tailSourceDuration)
        return requiredEnd > mediaDuration
    }

    static func nearestClip(
        from index: Array<TimelineItem>.Index,
        towardPartnerOf edge: ClipAudioFadeEdge,
        in items: [TimelineItem]
    ) -> (clip: Clip, skippedGapCount: Int)? {
        switch edge {
        case .leadingCrossfade:
            return nearestClip(from: index, direction: -1, in: items)
        case .trailingCrossfade:
            return nearestClip(from: index, direction: 1, in: items)
        case .fadeIn, .fadeOut:
            return nil
        }
    }

    static func nearestClip(
        from index: Array<TimelineItem>.Index,
        awayFromPartnerOf edge: ClipAudioFadeEdge,
        in items: [TimelineItem]
    ) -> (clip: Clip, skippedGapCount: Int)? {
        switch edge {
        case .leadingCrossfade:
            return nearestClip(from: index, direction: 1, in: items)
        case .trailingCrossfade:
            return nearestClip(from: index, direction: -1, in: items)
        case .fadeIn, .fadeOut:
            return nil
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
