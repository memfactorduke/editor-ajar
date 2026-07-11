// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation

// MARK: - Inspector tab extension lives in EditorAjarColorTypes (ClipInspectorTab)

// MARK: - Effects library catalog (FR-FX-002)

/// Coarse grouping for the browsable effects library. Engine kinds carry no category
/// metadata — display categories are app-layer only.
enum EffectLibraryCategory: String, CaseIterable, Identifiable, Sendable {
    case blur
    case enhance
    case color
    case stylize
    case spatial

    var id: String { rawValue }

    var localizedTitle: String {
        switch self {
        case .blur:
            return AppString.localized("effects.category.blur", "Blur")
        case .enhance:
            return AppString.localized("effects.category.enhance", "Enhance")
        case .color:
            return AppString.localized("effects.category.color", "Color")
        case .stylize:
            return AppString.localized("effects.category.stylize", "Stylize")
        case .spatial:
            return AppString.localized("effects.category.spatial", "Spatial")
        }
    }
}

/// One built-in library row. Excludes the bootstrap `placeholder` kind.
struct EffectLibraryItem: Identifiable, Equatable, Sendable {
    let kind: ClipEffectKind
    let category: EffectLibraryCategory

    var id: String { kind.rawValue }

    var localizedName: String {
        kind.localizedDisplayName
    }

    var localizedCategory: String {
        category.localizedTitle
    }

    /// Built-in FR-FX-002 library set (names from kind; categories app-side).
    ///
    /// `.lut` is intentionally omitted: the Effects tab has no table-import affordance, so a
    /// strength slider on an identity LUT is a dead-end. LUT import lives on the Color tab.
    static let all: [EffectLibraryItem] = [
        EffectLibraryItem(kind: .gaussianBlur, category: .blur),
        EffectLibraryItem(kind: .boxBlur, category: .blur),
        EffectLibraryItem(kind: .zoomBlur, category: .blur),
        EffectLibraryItem(kind: .sharpen, category: .enhance),
        EffectLibraryItem(kind: .glow, category: .enhance),
        EffectLibraryItem(kind: .vignette, category: .stylize),
        EffectLibraryItem(kind: .mirror, category: .spatial),
        EffectLibraryItem(kind: .mosaic, category: .stylize),
        EffectLibraryItem(kind: .colorAdjust, category: .color),
        EffectLibraryItem(kind: .posterize, category: .color),
        EffectLibraryItem(kind: .invert, category: .color),
        EffectLibraryItem(kind: .curves, category: .color),
    ]

    static func filtered(searchText: String) -> [EffectLibraryItem] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return all
        }
        let query = trimmed.lowercased()
        return all.filter { item in
            item.localizedName.lowercased().contains(query)
                || item.localizedCategory.lowercased().contains(query)
                || item.kind.rawValue.lowercased().contains(query)
        }
    }
}

extension ClipEffectKind {
    /// User-facing effect name (library + stack rows).
    var localizedDisplayName: String {
        switch self {
        case .placeholder:
            return AppString.localized("effects.kind.placeholder", "Placeholder")
        case .gaussianBlur:
            return AppString.localized("effects.kind.gaussianBlur", "Gaussian Blur")
        case .boxBlur:
            return AppString.localized("effects.kind.boxBlur", "Box Blur")
        case .zoomBlur:
            return AppString.localized("effects.kind.zoomBlur", "Zoom Blur")
        case .sharpen:
            return AppString.localized("effects.kind.sharpen", "Sharpen")
        case .glow:
            return AppString.localized("effects.kind.glow", "Glow")
        case .lut:
            return AppString.localized("effects.kind.lut", "LUT")
        case .vignette:
            return AppString.localized("effects.kind.vignette", "Vignette")
        case .mirror:
            return AppString.localized("effects.kind.mirror", "Mirror")
        case .mosaic:
            return AppString.localized("effects.kind.mosaic", "Mosaic")
        case .colorAdjust:
            return AppString.localized("effects.kind.colorAdjust", "Color Adjust")
        case .posterize:
            return AppString.localized("effects.kind.posterize", "Posterize")
        case .invert:
            return AppString.localized("effects.kind.invert", "Invert")
        case .curves:
            return AppString.localized("effects.kind.curves", "Curves")
        }
    }
}

// MARK: - Effect stack inspector state (FR-FX-003)

/// Snapshot for the Effects inspector tab (static base values).
struct SelectedEffectStackInspectorState: Equatable, Sendable {
    let clipName: String
    let nodes: [ClipEffectNode]
}

/// Scalar parameter row for one effect node (driven by kind definitions).
struct EffectScalarParameterSpec: Identifiable, Equatable, Sendable {
    /// Stable id within a kind (`radius`, `amount`, …).
    let id: String
    let title: String
    let range: ClosedRange<Double>

    var accessibilityIdentifier: String {
        "Effect Param \(title)"
    }
}

/// Discrete (non-slider) parameter controls.
enum EffectDiscreteParameterSpec: Equatable, Sendable {
    case mirrorAxis
}

/// Parameter layout for a definition (scalars + optional discrete).
struct EffectParameterLayout: Equatable, Sendable {
    let scalars: [EffectScalarParameterSpec]
    let discrete: EffectDiscreteParameterSpec?
    /// True when the kind has no editable parameters (e.g. invert).
    var isEmpty: Bool {
        scalars.isEmpty && discrete == nil
    }
}

enum EffectParameterCatalog {
    static func layout(for kind: ClipEffectKind) -> EffectParameterLayout {
        switch kind {
        case .placeholder:
            return EffectParameterLayout(
                scalars: [
                    EffectScalarParameterSpec(
                        id: "amount",
                        title: AppString.localized("effects.param.amount", "Amount"),
                        range: 0...1
                    ),
                ],
                discrete: nil
            )
        case .gaussianBlur:
            return EffectParameterLayout(
                scalars: [
                    EffectScalarParameterSpec(
                        id: "radius",
                        title: AppString.localized("effects.param.radius", "Radius"),
                        range: 0...64
                    ),
                ],
                discrete: nil
            )
        case .boxBlur:
            return EffectParameterLayout(
                scalars: [
                    EffectScalarParameterSpec(
                        id: "radius",
                        title: AppString.localized("effects.param.radius", "Radius"),
                        range: 0...16
                    ),
                ],
                discrete: nil
            )
        case .zoomBlur:
            return EffectParameterLayout(
                scalars: [
                    EffectScalarParameterSpec(
                        id: "amount",
                        title: AppString.localized("effects.param.amount", "Amount"),
                        range: 0...1
                    ),
                    EffectScalarParameterSpec(
                        id: "centerX",
                        title: AppString.localized("effects.param.centerX", "Center X"),
                        range: 0...1
                    ),
                    EffectScalarParameterSpec(
                        id: "centerY",
                        title: AppString.localized("effects.param.centerY", "Center Y"),
                        range: 0...1
                    ),
                ],
                discrete: nil
            )
        case .sharpen:
            return EffectParameterLayout(
                scalars: [
                    EffectScalarParameterSpec(
                        id: "amount",
                        title: AppString.localized("effects.param.amount", "Amount"),
                        range: 0...1
                    ),
                    EffectScalarParameterSpec(
                        id: "radius",
                        title: AppString.localized("effects.param.radius", "Radius"),
                        range: 0...8
                    ),
                ],
                discrete: nil
            )
        case .glow:
            return EffectParameterLayout(
                scalars: [
                    EffectScalarParameterSpec(
                        id: "radius",
                        title: AppString.localized("effects.param.radius", "Radius"),
                        range: 0...64
                    ),
                    EffectScalarParameterSpec(
                        id: "amount",
                        title: AppString.localized("effects.param.amount", "Amount"),
                        range: 0...1
                    ),
                ],
                discrete: nil
            )
        case .lut:
            return EffectParameterLayout(
                scalars: [
                    EffectScalarParameterSpec(
                        id: "strength",
                        title: AppString.localized("effects.param.strength", "Strength"),
                        range: 0...1
                    ),
                ],
                discrete: nil
            )
        case .vignette:
            return EffectParameterLayout(
                scalars: [
                    EffectScalarParameterSpec(
                        id: "amount",
                        title: AppString.localized("effects.param.amount", "Amount"),
                        range: 0...1
                    ),
                    EffectScalarParameterSpec(
                        id: "radius",
                        title: AppString.localized("effects.param.radius", "Radius"),
                        range: 0...1
                    ),
                    EffectScalarParameterSpec(
                        id: "softness",
                        title: AppString.localized("effects.param.softness", "Softness"),
                        range: 0...1
                    ),
                ],
                discrete: nil
            )
        case .mirror:
            return EffectParameterLayout(scalars: [], discrete: .mirrorAxis)
        case .mosaic:
            return EffectParameterLayout(
                scalars: [
                    EffectScalarParameterSpec(
                        id: "cellSize",
                        title: AppString.localized("effects.param.cellSize", "Cell Size"),
                        range: 1...256
                    ),
                ],
                discrete: nil
            )
        case .colorAdjust:
            return EffectParameterLayout(
                scalars: [
                    EffectScalarParameterSpec(
                        id: "brightness",
                        title: AppString.localized("effects.param.brightness", "Brightness"),
                        range: -1...1
                    ),
                    EffectScalarParameterSpec(
                        id: "contrast",
                        title: AppString.localized("effects.param.contrast", "Contrast"),
                        range: 0...4
                    ),
                    EffectScalarParameterSpec(
                        id: "saturation",
                        title: AppString.localized("effects.param.saturation", "Saturation"),
                        range: 0...4
                    ),
                    EffectScalarParameterSpec(
                        id: "tint",
                        title: AppString.localized("effects.param.tint", "Tint"),
                        range: -1...1
                    ),
                ],
                discrete: nil
            )
        case .posterize:
            return EffectParameterLayout(
                scalars: [
                    EffectScalarParameterSpec(
                        id: "levels",
                        title: AppString.localized("effects.param.levels", "Levels"),
                        range: 2...256
                    ),
                ],
                discrete: nil
            )
        case .invert:
            return EffectParameterLayout(scalars: [], discrete: nil)
        case .curves:
            return EffectParameterLayout(
                scalars: [
                    EffectScalarParameterSpec(
                        id: "strength",
                        title: AppString.localized("effects.param.strength", "Strength"),
                        range: 0...1
                    ),
                ],
                discrete: nil
            )
        }
    }

    static func scalarValue(
        parameterID: String,
        in definition: ClipEffectDefinition
    ) -> RationalValue? {
        switch definition {
        case .placeholder(let p):
            return parameterID == "amount" ? p.amount : nil
        case .gaussianBlur(let p):
            return parameterID == "radius" ? p.radius : nil
        case .boxBlur(let p):
            return parameterID == "radius" ? p.radius : nil
        case .zoomBlur(let p):
            switch parameterID {
            case "amount": return p.amount
            case "centerX": return p.centerX
            case "centerY": return p.centerY
            default: return nil
            }
        case .sharpen(let p):
            switch parameterID {
            case "amount": return p.amount
            case "radius": return p.radius
            default: return nil
            }
        case .glow(let p):
            switch parameterID {
            case "radius": return p.radius
            case "amount": return p.amount
            default: return nil
            }
        case .lut(let p):
            return parameterID == "strength" ? p.strength : nil
        case .vignette(let p):
            switch parameterID {
            case "amount": return p.amount
            case "radius": return p.radius
            case "softness": return p.softness
            default: return nil
            }
        case .mirror:
            return nil
        case .mosaic(let p):
            return parameterID == "cellSize" ? p.cellSize : nil
        case .colorAdjust(let p):
            switch parameterID {
            case "brightness": return p.brightness
            case "contrast": return p.contrast
            case "saturation": return p.saturation
            case "tint": return p.tint
            default: return nil
            }
        case .posterize(let p):
            return parameterID == "levels" ? p.levels : nil
        case .invert:
            return nil
        case .curves(let p):
            return parameterID == "strength" ? p.strength : nil
        }
    }

    /// Returns a new definition with one scalar replaced, or `nil` if the id does not apply.
    static func settingScalar(  // swiftlint:disable:this cyclomatic_complexity function_body_length
        parameterID: String,
        to value: RationalValue,
        in definition: ClipEffectDefinition
    ) -> ClipEffectDefinition? {
        switch definition {
        case .placeholder:
            guard parameterID == "amount" else { return nil }
            return .placeholder(ClipPlaceholderEffectParameters(amount: value))
        case .gaussianBlur:
            guard parameterID == "radius" else { return nil }
            return .gaussianBlur(ClipGaussianBlurParameters(radius: value))
        case .boxBlur:
            guard parameterID == "radius" else { return nil }
            return .boxBlur(ClipBoxBlurParameters(radius: value))
        case .zoomBlur(let p):
            switch parameterID {
            case "amount":
                return .zoomBlur(
                    ClipZoomBlurParameters(amount: value, centerX: p.centerX, centerY: p.centerY)
                )
            case "centerX":
                return .zoomBlur(
                    ClipZoomBlurParameters(amount: p.amount, centerX: value, centerY: p.centerY)
                )
            case "centerY":
                return .zoomBlur(
                    ClipZoomBlurParameters(amount: p.amount, centerX: p.centerX, centerY: value)
                )
            default:
                return nil
            }
        case .sharpen(let p):
            switch parameterID {
            case "amount":
                return .sharpen(ClipSharpenParameters(amount: value, radius: p.radius))
            case "radius":
                return .sharpen(ClipSharpenParameters(amount: p.amount, radius: value))
            default:
                return nil
            }
        case .glow(let p):
            switch parameterID {
            case "radius":
                return .glow(ClipGlowParameters(radius: value, amount: p.amount))
            case "amount":
                return .glow(ClipGlowParameters(radius: p.radius, amount: value))
            default:
                return nil
            }
        case .lut(let p):
            guard parameterID == "strength" else { return nil }
            return .lut(
                ClipLUTEffectParameters(table: p.table, strength: value, placement: p.placement)
            )
        case .vignette(let p):
            switch parameterID {
            case "amount":
                return .vignette(
                    ClipVignetteParameters(amount: value, radius: p.radius, softness: p.softness)
                )
            case "radius":
                return .vignette(
                    ClipVignetteParameters(amount: p.amount, radius: value, softness: p.softness)
                )
            case "softness":
                return .vignette(
                    ClipVignetteParameters(amount: p.amount, radius: p.radius, softness: value)
                )
            default:
                return nil
            }
        case .mirror:
            return nil
        case .mosaic:
            guard parameterID == "cellSize" else { return nil }
            return .mosaic(ClipMosaicParameters(cellSize: value))
        case .colorAdjust(let p):
            switch parameterID {
            case "brightness":
                return .colorAdjust(
                    ClipColorAdjustParameters(
                        brightness: value,
                        contrast: p.contrast,
                        saturation: p.saturation,
                        tint: p.tint
                    )
                )
            case "contrast":
                return .colorAdjust(
                    ClipColorAdjustParameters(
                        brightness: p.brightness,
                        contrast: value,
                        saturation: p.saturation,
                        tint: p.tint
                    )
                )
            case "saturation":
                return .colorAdjust(
                    ClipColorAdjustParameters(
                        brightness: p.brightness,
                        contrast: p.contrast,
                        saturation: value,
                        tint: p.tint
                    )
                )
            case "tint":
                return .colorAdjust(
                    ClipColorAdjustParameters(
                        brightness: p.brightness,
                        contrast: p.contrast,
                        saturation: p.saturation,
                        tint: value
                    )
                )
            default:
                return nil
            }
        case .posterize:
            guard parameterID == "levels" else { return nil }
            return .posterize(ClipPosterizeParameters(levels: value))
        case .invert:
            return nil
        case .curves(let p):
            guard parameterID == "strength" else { return nil }
            return .curves(
                ClipCurvesEffectParameters(
                    rgb: p.rgb,
                    red: p.red,
                    green: p.green,
                    blue: p.blue,
                    strength: value
                )
            )
        }
    }

    static func mirrorAxis(in definition: ClipEffectDefinition) -> ClipMirrorAxis? {
        if case .mirror(let parameters) = definition {
            return parameters.axis
        }
        return nil
    }

    static func settingMirrorAxis(
        _ axis: ClipMirrorAxis,
        in definition: ClipEffectDefinition
    ) -> ClipEffectDefinition? {
        guard case .mirror = definition else {
            return nil
        }
        return .mirror(ClipMirrorParameters(axis: axis))
    }
}

extension ClipMirrorAxis {
    var localizedTitle: String {
        switch self {
        case .horizontal:
            return AppString.localized("effects.mirror.horizontal", "Horizontal")
        case .vertical:
            return AppString.localized("effects.mirror.vertical", "Vertical")
        case .quad:
            return AppString.localized("effects.mirror.quad", "Quad")
        }
    }
}

// MARK: - Video transitions (FR-FX-001)

/// Inspector / menu snapshot for the cut after the selected video clip.
struct SelectedVideoTransitionState: Equatable, Sendable {
    /// Outgoing clip name (owns the trailing transition record).
    let clipName: String
    /// True when the next timeline item is an abutting video clip.
    let hasAdjacentIncoming: Bool
    /// Existing trailing transition on the selected (outgoing) clip, if any.
    let transition: ClipVideoTransition?
}

extension ClipVideoTransitionKind {
    var localizedDisplayName: String {
        switch self {
        case .crossDissolve:
            return AppString.localized("transition.kind.crossDissolve", "Cross Dissolve")
        case .dipToColor:
            return AppString.localized("transition.kind.dipToColor", "Dip to Color")
        case .fade:
            return AppString.localized("transition.kind.fade", "Fade")
        case .push:
            return AppString.localized("transition.kind.push", "Push")
        case .slide:
            return AppString.localized("transition.kind.slide", "Slide")
        case .wipe:
            return AppString.localized("transition.kind.wipe", "Wipe")
        case .zoom:
            return AppString.localized("transition.kind.zoom", "Zoom")
        }
    }

    /// Whether the kind accepts a direction parameter.
    var usesDirection: Bool {
        switch self {
        case .push, .slide, .wipe:
            return true
        case .crossDissolve, .dipToColor, .fade, .zoom:
            return false
        }
    }
}

extension ClipVideoTransitionDirection {
    var localizedDisplayName: String {
        switch self {
        case .left:
            return AppString.localized("transition.direction.left", "Left")
        case .right:
            return AppString.localized("transition.direction.right", "Right")
        case .top:
            return AppString.localized("transition.direction.top", "Top")
        case .bottom:
            return AppString.localized("transition.direction.bottom", "Bottom")
        case .topLeft:
            return AppString.localized("transition.direction.topLeft", "Top Left")
        case .topRight:
            return AppString.localized("transition.direction.topRight", "Top Right")
        case .bottomLeft:
            return AppString.localized("transition.direction.bottomLeft", "Bottom Left")
        case .bottomRight:
            return AppString.localized("transition.direction.bottomRight", "Bottom Right")
        }
    }

    /// Directions valid for `kind` (wipe includes diagonals; push/slide are linear only).
    static func options(for kind: ClipVideoTransitionKind) -> [ClipVideoTransitionDirection] {
        switch kind {
        case .wipe:
            return Array(ClipVideoTransitionDirection.allCases)
        case .push, .slide:
            return [.left, .right, .top, .bottom]
        case .crossDissolve, .dipToColor, .fade, .zoom:
            return []
        }
    }
}

/// Typed transition UI refusals (non-blocking; never crash the session).
enum EditorAjarVideoTransitionError: Error, Equatable, Sendable {
    case noProject
    case projectReadOnly
    case noVideoClipSelected
    case requiresAdjacentClips
    case transitionNotFound
    case invalidDuration
    case applyFailed(String)
}
