// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation

/// Snapshot for the FR-TXT-001/002/004 title inspector when a title clip is selected.
struct SelectedTitleInspectorState: Equatable, Sendable {
    let clipName: String
    let sequenceID: UUID
    let trackID: UUID
    let clipID: UUID
    let title: TitleSource
    let selectedBoxID: UUID?
    let selectedBox: TitleTextBox?
    let clipDuration: RationalTime
}

/// App-side defaults for new title clips (not project-persisted — no schemaMinor bump).
enum TitleInsertDefaults {
    /// Default title timeline placement length in whole seconds.
    static let durationSeconds: Int64 = 5

    /// Default UTF-8 text for a new title box / clip.
    static let text = "Title"

    /// Localized clip name for insert.
    static var clipName: String {
        AppString.localized("title.insert.clipName", "Title")
    }

    static func duration() throws -> RationalTime {
        try RationalTime(value: durationSeconds, timescale: 1)
    }

    /// Default box size and origin centered on the sequence canvas.
    static func defaultBox(
        id: UUID = UUID(),
        canvas: PixelDimensions,
        text: String = text,
        style: TitleTextStyle = .default
    ) -> TitleTextBox {
        let widthValue = Int64(min(400, max(120, canvas.width - 80)))
        let heightValue: Int64 = 80
        let width = RationalValue(widthValue)
        let height = RationalValue(heightValue)
        let originX = RationalValue(max(0, (Int64(canvas.width) - widthValue) / 2))
        let originY = RationalValue(max(0, (Int64(canvas.height) - heightValue) / 3))
        return TitleTextBox(
            id: id,
            text: text,
            origin: CanvasPoint(x: originX, y: originY),
            width: width,
            height: height,
            style: style
        )
    }

    static func defaultTitleSource(canvas: PixelDimensions) -> TitleSource {
        TitleSource(boxes: [defaultBox(canvas: canvas)])
    }
}

/// Scalar title-style controls shown as sliders / numeric fields (FR-TXT-001/002).
enum TitleStyleScalarField: String, CaseIterable, Identifiable, Sendable {
    case fontSize
    case tracking
    case leading
    case strokeWidth
    case shadowOffsetX
    case shadowOffsetY
    case shadowBlur
    case shadowOpacity
    case backgroundPadding
    case backgroundCornerRadius
    case backgroundOpacity
    case gradientAngle

    var id: String { rawValue }

    var localizedTitle: String {
        switch self {
        case .fontSize:
            return AppString.localized("title.field.fontSize", "Size")
        case .tracking:
            return AppString.localized("title.field.tracking", "Tracking")
        case .leading:
            return AppString.localized("title.field.leading", "Leading")
        case .strokeWidth:
            return AppString.localized("title.field.strokeWidth", "Stroke Width")
        case .shadowOffsetX:
            return AppString.localized("title.field.shadowOffsetX", "Shadow X")
        case .shadowOffsetY:
            return AppString.localized("title.field.shadowOffsetY", "Shadow Y")
        case .shadowBlur:
            return AppString.localized("title.field.shadowBlur", "Shadow Blur")
        case .shadowOpacity:
            return AppString.localized("title.field.shadowOpacity", "Shadow Opacity")
        case .backgroundPadding:
            return AppString.localized("title.field.backgroundPadding", "Box Padding")
        case .backgroundCornerRadius:
            return AppString.localized("title.field.backgroundCorner", "Box Corner")
        case .backgroundOpacity:
            return AppString.localized("title.field.backgroundOpacity", "Box Opacity")
        case .gradientAngle:
            return AppString.localized("title.field.gradientAngle", "Gradient Angle")
        }
    }

    var accessibilityIdentifier: String {
        "Title \(rawValue)"
    }

    var range: ClosedRange<Double> {
        switch self {
        case .fontSize:
            return TitleSource.minimumFontSize.doubleValue...TitleSource.maximumFontSize.doubleValue
        case .tracking:
            return TitleSource.minimumTracking.doubleValue...TitleSource.maximumTracking.doubleValue
        case .leading:
            return TitleSource.minimumLeading.doubleValue...TitleSource.maximumLeading.doubleValue
        case .strokeWidth:
            return TitleSource.minimumStrokeWidth.doubleValue...TitleSource.maximumStrokeWidth
                .doubleValue
        case .shadowOffsetX, .shadowOffsetY:
            return TitleSource.minimumDropShadowOffset.doubleValue...TitleSource
                .maximumDropShadowOffset.doubleValue
        case .shadowBlur:
            return 0...TitleSource.maximumDropShadowBlurRadius.doubleValue
        case .shadowOpacity, .backgroundOpacity:
            return 0...1
        case .backgroundPadding:
            return 0...TitleSource.maximumBackgroundPadding.doubleValue
        case .backgroundCornerRadius:
            return 0...TitleSource.maximumBackgroundCornerRadius.doubleValue
        case .gradientAngle:
            return TitleSource.minimumGradientAngle.doubleValue...TitleSource.maximumGradientAngle
                .doubleValue
        }
    }
}

/// RGB channel groups on the selected title box style (FR-TXT-001/002).
enum TitleColorTarget: String, CaseIterable, Identifiable, Sendable {
    case fill
    case stroke
    case shadow
    case background
    case gradientStart
    case gradientEnd

    var id: String { rawValue }

    var localizedTitle: String {
        switch self {
        case .fill:
            return AppString.localized("title.color.fill", "Fill Color")
        case .stroke:
            return AppString.localized("title.color.stroke", "Stroke Color")
        case .shadow:
            return AppString.localized("title.color.shadow", "Shadow Color")
        case .background:
            return AppString.localized("title.color.background", "Background Color")
        case .gradientStart:
            return AppString.localized("title.color.gradientStart", "Gradient Start")
        case .gradientEnd:
            return AppString.localized("title.color.gradientEnd", "Gradient End")
        }
    }
}

/// Builds/replaces `TitleTextStyle` / box fields for the inspector.
enum TitleStyleEditor {
    static func copying(
        _ style: TitleTextStyle,
        fontFamily: String? = nil,
        fontSize: RationalValue? = nil,
        fontWeight: TitleFontWeight? = nil,
        color: ClipRGBColor? = nil,
        tracking: RationalValue? = nil,
        leading: RationalValue? = nil,
        alignment: TitleTextAlignment? = nil,
        stroke: TitleStrokeStyle?? = nil,
        dropShadow: TitleDropShadowStyle?? = nil,
        gradientFill: TitleLinearGradientFill?? = nil
    ) -> TitleTextStyle {
        TitleTextStyle(
            fontFamily: fontFamily ?? style.fontFamily,
            fontSize: fontSize ?? style.fontSize,
            fontWeight: fontWeight ?? style.fontWeight,
            color: color ?? style.color,
            tracking: tracking ?? style.tracking,
            leading: leading ?? style.leading,
            alignment: alignment ?? style.alignment,
            stroke: stroke ?? style.stroke,
            dropShadow: dropShadow ?? style.dropShadow,
            gradientFill: gradientFill ?? style.gradientFill
        )
    }

    static func copying(
        _ stroke: TitleStrokeStyle,
        width: RationalValue? = nil,
        color: ClipRGBColor? = nil,
        join: TitleStrokeJoin? = nil
    ) -> TitleStrokeStyle {
        TitleStrokeStyle(
            width: width ?? stroke.width,
            color: color ?? stroke.color,
            join: join ?? stroke.join
        )
    }

    static func copying(
        _ shadow: TitleDropShadowStyle,
        offsetX: RationalValue? = nil,
        offsetY: RationalValue? = nil,
        blurRadius: RationalValue? = nil,
        color: ClipRGBColor? = nil,
        opacity: RationalValue? = nil
    ) -> TitleDropShadowStyle {
        TitleDropShadowStyle(
            offsetX: offsetX ?? shadow.offsetX,
            offsetY: offsetY ?? shadow.offsetY,
            blurRadius: blurRadius ?? shadow.blurRadius,
            color: color ?? shadow.color,
            opacity: opacity ?? shadow.opacity
        )
    }

    static func copying(
        _ background: TitleBackgroundBoxStyle,
        padding: RationalValue? = nil,
        cornerRadius: RationalValue? = nil,
        fillColor: ClipRGBColor? = nil,
        opacity: RationalValue? = nil
    ) -> TitleBackgroundBoxStyle {
        TitleBackgroundBoxStyle(
            padding: padding ?? background.padding,
            cornerRadius: cornerRadius ?? background.cornerRadius,
            fillColor: fillColor ?? background.fillColor,
            opacity: opacity ?? background.opacity
        )
    }

    static func copying(
        _ gradient: TitleLinearGradientFill,
        startColor: ClipRGBColor? = nil,
        endColor: ClipRGBColor? = nil,
        angleDegrees: RationalValue? = nil
    ) -> TitleLinearGradientFill {
        TitleLinearGradientFill(
            startColor: startColor ?? gradient.startColor,
            endColor: endColor ?? gradient.endColor,
            angleDegrees: angleDegrees ?? gradient.angleDegrees
        )
    }

    static func copying(
        _ color: ClipRGBColor,
        component: ColorInspectorChannelComponent,
        value: RationalValue
    ) -> ClipRGBColor {
        switch component {
        case .red:
            return ClipRGBColor(red: value, green: color.green, blue: color.blue)
        case .green:
            return ClipRGBColor(red: color.red, green: value, blue: color.blue)
        case .blue:
            return ClipRGBColor(red: color.red, green: color.green, blue: value)
        }
    }

    static func scalarValue(_ field: TitleStyleScalarField, in box: TitleTextBox) -> RationalValue {
        switch field {
        case .fontSize:
            return box.style.fontSize
        case .tracking:
            return box.style.tracking
        case .leading:
            return box.style.leading
        case .strokeWidth:
            return box.style.stroke?.width ?? .zero
        case .shadowOffsetX:
            return box.style.dropShadow?.offsetX ?? RationalValue(4)
        case .shadowOffsetY:
            return box.style.dropShadow?.offsetY ?? RationalValue(4)
        case .shadowBlur:
            return box.style.dropShadow?.blurRadius ?? RationalValue(4)
        case .shadowOpacity:
            return box.style.dropShadow?.opacity ?? .one
        case .backgroundPadding:
            return box.backgroundBox?.padding ?? RationalValue(8)
        case .backgroundCornerRadius:
            return box.backgroundBox?.cornerRadius ?? RationalValue(4)
        case .backgroundOpacity:
            return box.backgroundBox?.opacity ?? .one
        case .gradientAngle:
            return box.style.gradientFill?.angleDegrees ?? .zero
        }
    }

    static func color(_ target: TitleColorTarget, in box: TitleTextBox) -> ClipRGBColor {
        switch target {
        case .fill:
            return box.style.color
        case .stroke:
            return box.style.stroke?.color
                ?? ClipRGBColor(red: .zero, green: .zero, blue: .zero)
        case .shadow:
            return box.style.dropShadow?.color
                ?? ClipRGBColor(red: .zero, green: .zero, blue: .zero)
        case .background:
            return box.backgroundBox?.fillColor
                ?? ClipRGBColor(red: .zero, green: .zero, blue: .zero)
        case .gradientStart:
            return box.style.gradientFill?.startColor
                ?? ClipRGBColor(red: .one, green: .one, blue: .one)
        case .gradientEnd:
            return box.style.gradientFill?.endColor
                ?? ClipRGBColor(red: .zero, green: .zero, blue: .zero)
        }
    }

    static func applying(
        _ field: TitleStyleScalarField,
        value: RationalValue,
        to box: TitleTextBox
    ) -> TitleTextBox {
        switch field {
        case .fontSize:
            return CanvasTitleBoxEditor.copying(
                box,
                style: copying(box.style, fontSize: value)
            )
        case .tracking:
            return CanvasTitleBoxEditor.copying(
                box,
                style: copying(box.style, tracking: value)
            )
        case .leading:
            return CanvasTitleBoxEditor.copying(
                box,
                style: copying(box.style, leading: value)
            )
        case .strokeWidth:
            let stroke = box.style.stroke ?? TitleStrokeStyle()
            return CanvasTitleBoxEditor.copying(
                box,
                style: copying(box.style, stroke: .some(copying(stroke, width: value)))
            )
        case .shadowOffsetX:
            let shadow = box.style.dropShadow ?? TitleDropShadowStyle()
            return CanvasTitleBoxEditor.copying(
                box,
                style: copying(box.style, dropShadow: .some(copying(shadow, offsetX: value)))
            )
        case .shadowOffsetY:
            let shadow = box.style.dropShadow ?? TitleDropShadowStyle()
            return CanvasTitleBoxEditor.copying(
                box,
                style: copying(box.style, dropShadow: .some(copying(shadow, offsetY: value)))
            )
        case .shadowBlur:
            let shadow = box.style.dropShadow ?? TitleDropShadowStyle()
            return CanvasTitleBoxEditor.copying(
                box,
                style: copying(box.style, dropShadow: .some(copying(shadow, blurRadius: value)))
            )
        case .shadowOpacity:
            let shadow = box.style.dropShadow ?? TitleDropShadowStyle()
            return CanvasTitleBoxEditor.copying(
                box,
                style: copying(box.style, dropShadow: .some(copying(shadow, opacity: value)))
            )
        case .backgroundPadding:
            let background = box.backgroundBox ?? TitleBackgroundBoxStyle()
            return CanvasTitleBoxEditor.copying(
                box,
                backgroundBox: .some(copying(background, padding: value))
            )
        case .backgroundCornerRadius:
            let background = box.backgroundBox ?? TitleBackgroundBoxStyle()
            return CanvasTitleBoxEditor.copying(
                box,
                backgroundBox: .some(copying(background, cornerRadius: value))
            )
        case .backgroundOpacity:
            let background = box.backgroundBox ?? TitleBackgroundBoxStyle()
            return CanvasTitleBoxEditor.copying(
                box,
                backgroundBox: .some(copying(background, opacity: value))
            )
        case .gradientAngle:
            let gradient = box.style.gradientFill ?? TitleLinearGradientFill()
            return CanvasTitleBoxEditor.copying(
                box,
                style: copying(
                    box.style,
                    gradientFill: .some(copying(gradient, angleDegrees: value))
                )
            )
        }
    }

    static func applying(
        colorTarget: TitleColorTarget,
        component: ColorInspectorChannelComponent,
        value: RationalValue,
        to box: TitleTextBox
    ) -> TitleTextBox {
        let nextColor = copying(color(colorTarget, in: box), component: component, value: value)
        switch colorTarget {
        case .fill:
            return CanvasTitleBoxEditor.copying(box, style: copying(box.style, color: nextColor))
        case .stroke:
            let stroke = box.style.stroke ?? TitleStrokeStyle()
            return CanvasTitleBoxEditor.copying(
                box,
                style: copying(box.style, stroke: .some(copying(stroke, color: nextColor)))
            )
        case .shadow:
            let shadow = box.style.dropShadow ?? TitleDropShadowStyle()
            return CanvasTitleBoxEditor.copying(
                box,
                style: copying(box.style, dropShadow: .some(copying(shadow, color: nextColor)))
            )
        case .background:
            let background = box.backgroundBox ?? TitleBackgroundBoxStyle()
            return CanvasTitleBoxEditor.copying(
                box,
                backgroundBox: .some(copying(background, fillColor: nextColor))
            )
        case .gradientStart:
            let gradient = box.style.gradientFill ?? TitleLinearGradientFill()
            return CanvasTitleBoxEditor.copying(
                box,
                style: copying(
                    box.style,
                    gradientFill: .some(copying(gradient, startColor: nextColor))
                )
            )
        case .gradientEnd:
            let gradient = box.style.gradientFill ?? TitleLinearGradientFill()
            return CanvasTitleBoxEditor.copying(
                box,
                style: copying(
                    box.style,
                    gradientFill: .some(copying(gradient, endColor: nextColor))
                )
            )
        }
    }
}

extension TitleFontWeight {
    var localizedTitle: String {
        switch self {
        case .ultraLight:
            return AppString.localized("title.weight.ultraLight", "Ultra Light")
        case .thin:
            return AppString.localized("title.weight.thin", "Thin")
        case .light:
            return AppString.localized("title.weight.light", "Light")
        case .regular:
            return AppString.localized("title.weight.regular", "Regular")
        case .medium:
            return AppString.localized("title.weight.medium", "Medium")
        case .semibold:
            return AppString.localized("title.weight.semibold", "Semibold")
        case .bold:
            return AppString.localized("title.weight.bold", "Bold")
        case .heavy:
            return AppString.localized("title.weight.heavy", "Heavy")
        case .black:
            return AppString.localized("title.weight.black", "Black")
        }
    }
}

extension TitleTextAlignment {
    var localizedTitle: String {
        switch self {
        case .left:
            return AppString.localized("title.alignment.left", "Left")
        case .center:
            return AppString.localized("title.alignment.center", "Center")
        case .right:
            return AppString.localized("title.alignment.right", "Right")
        case .justified:
            return AppString.localized("title.alignment.justified", "Justified")
        }
    }
}

extension TitleStrokeJoin {
    var localizedTitle: String {
        switch self {
        case .miter:
            return AppString.localized("title.strokeJoin.miter", "Miter")
        case .round:
            return AppString.localized("title.strokeJoin.round", "Round")
        case .bevel:
            return AppString.localized("title.strokeJoin.bevel", "Bevel")
        }
    }
}

extension TitleAnimationPresetKind {
    var localizedTitle: String {
        switch self {
        case .fade:
            return AppString.localized("title.preset.fade", "Fade")
        case .slide:
            return AppString.localized("title.preset.slide", "Slide")
        case .typewriter:
            return AppString.localized("title.preset.typewriter", "Typewriter")
        case .pop:
            return AppString.localized("title.preset.pop", "Pop")
        case .lowerThird:
            return AppString.localized("title.preset.lowerThird", "Lower Third")
        }
    }
}

extension TitleAnimationDirection {
    var localizedTitle: String {
        switch self {
        case .left:
            return AppString.localized("title.direction.left", "Left")
        case .right:
            return AppString.localized("title.direction.right", "Right")
        case .up:
            return AppString.localized("title.direction.up", "Up")
        case .down:
            return AppString.localized("title.direction.down", "Down")
        }
    }
}
