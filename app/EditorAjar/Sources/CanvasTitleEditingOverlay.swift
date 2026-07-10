// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import AppKit
import SwiftUI

struct CanvasTitleBoxReference: Hashable, Sendable {
    let sequenceID: UUID
    let trackID: UUID
    let clipID: UUID
    let boxID: UUID
}

struct CanvasTitleBoxLayout: Identifiable, Equatable, Sendable {
    let canvasSize: PixelDimensions
    let reference: CanvasTitleBoxReference
    let box: TitleTextBox
    let boxIndex: Int
    let clipName: String
    let clipTransform: ClipTransform
    let isEditable: Bool

    var id: CanvasTitleBoxReference { reference }
}

enum CanvasTitleNudgeDirection: Sendable {
    case left
    case right
    case up
    case down
}

enum CanvasTitleBoxEditor {
    static func copying(
        _ box: TitleTextBox,
        text: String? = nil,
        origin: CanvasPoint? = nil
    ) -> TitleTextBox {
        TitleTextBox(
            id: box.id,
            text: text ?? box.text,
            origin: origin ?? box.origin,
            width: box.width,
            height: box.height,
            style: box.style,
            backgroundBox: box.backgroundBox
        )
    }
}

enum CanvasTitlePositioning {
    static let actionSafeInsetFraction = 0.05
    static let titleSafeInsetFraction = 0.10
    static let snapToleranceScreenPoints = 8.0

    static func draggedOrigin(
        for layout: CanvasTitleBoxLayout,
        translationX: Double,
        translationY: Double,
        canvasScale: Double
    ) -> CanvasPoint {
        let delta = sourceDelta(
            outputX: translationX / max(0.000_001, canvasScale),
            outputY: translationY / max(0.000_001, canvasScale),
            layout: layout
        )
        let proposedX = layout.box.origin.x.doubleValue + delta.x
        let proposedY = layout.box.origin.y.doubleValue + delta.y
        let tolerance = snapToleranceScreenPoints / max(0.000_001, canvasScale)
        return constrainedOrigin(
            x: proposedX,
            y: proposedY,
            layout: layout,
            snapTolerance: tolerance
        )
    }

    static func nudgedOrigin(
        for layout: CanvasTitleBoxLayout,
        direction: CanvasTitleNudgeDirection,
        step: Double
    ) -> CanvasPoint {
        let outputDelta: (x: Double, y: Double)
        switch direction {
        case .left:
            outputDelta = (-step, 0)
        case .right:
            outputDelta = (step, 0)
        case .up:
            outputDelta = (0, -step)
        case .down:
            outputDelta = (0, step)
        }
        let sourceDelta = sourceDelta(
            outputX: outputDelta.x,
            outputY: outputDelta.y,
            layout: layout
        )
        return constrainedOrigin(
            x: layout.box.origin.x.doubleValue + sourceDelta.x,
            y: layout.box.origin.y.doubleValue + sourceDelta.y,
            layout: layout,
            snapTolerance: nil
        )
    }

    private static func sourceDelta(
        outputX: Double,
        outputY: Double,
        layout: CanvasTitleBoxLayout
    ) -> (x: Double, y: Double) {
        let transform = layout.clipTransform
        let radians = -rotationDegrees(transform.rotation) * .pi / 180.0
        let cosine = cos(radians)
        let sine = sin(radians)
        let rotatedX = (outputX * cosine) - (outputY * sine)
        let rotatedY = (outputX * sine) + (outputY * cosine)
        let scaleX = nonzeroScale(transform.scale.x.doubleValue)
        let scaleY = nonzeroScale(transform.scale.y.doubleValue)
        let unflippedX = rotatedX / scaleX
        let unflippedY = rotatedY / scaleY
        return (
            transform.flip.horizontal ? -unflippedX : unflippedX,
            transform.flip.vertical ? -unflippedY : unflippedY
        )
    }

    private static func constrainedOrigin(
        x: Double,
        y: Double,
        layout: CanvasTitleBoxLayout,
        snapTolerance: Double?
    ) -> CanvasPoint {
        let canvasWidth = Double(layout.canvasSize.width)
        let canvasHeight = Double(layout.canvasSize.height)
        let boxWidth = layout.box.width.doubleValue
        let boxHeight = layout.box.height.doubleValue
        let maximumX = max(0, canvasWidth - boxWidth)
        let maximumY = max(0, canvasHeight - boxHeight)

        var constrainedX = min(max(0, x), maximumX)
        var constrainedY = min(max(0, y), maximumY)
        if let snapTolerance {
            let bounds = outputBounds(
                originX: constrainedX,
                originY: constrainedY,
                layout: layout
            )
            let outputAdjustment = snapAdjustment(
                bounds: bounds,
                canvasWidth: canvasWidth,
                canvasHeight: canvasHeight,
                tolerance: snapTolerance
            )
            let sourceAdjustment = sourceDelta(
                outputX: outputAdjustment.x,
                outputY: outputAdjustment.y,
                layout: layout
            )
            constrainedX += sourceAdjustment.x
            constrainedY += sourceAdjustment.y
        }
        constrainedX = min(max(0, constrainedX), maximumX)
        constrainedY = min(max(0, constrainedY), maximumY)

        return CanvasPoint(
            x: RationalValue.approximating(constrainedX),
            y: RationalValue.approximating(constrainedY)
        )
    }

    private static func outputBounds(
        originX: Double,
        originY: Double,
        layout: CanvasTitleBoxLayout
    ) -> CGRect {
        let maximumX = originX + layout.box.width.doubleValue
        let maximumY = originY + layout.box.height.doubleValue
        let points = [
            CGPoint(x: originX, y: originY),
            CGPoint(x: maximumX, y: originY),
            CGPoint(x: originX, y: maximumY),
            CGPoint(x: maximumX, y: maximumY)
        ].map { transformedPoint($0, layout: layout) }
        let xValues = points.map(\.x)
        let yValues = points.map(\.y)
        let minimumX = xValues.min() ?? 0
        let minimumY = yValues.min() ?? 0
        let width = (xValues.max() ?? minimumX) - minimumX
        let height = (yValues.max() ?? minimumY) - minimumY
        return CGRect(x: minimumX, y: minimumY, width: width, height: height)
    }

    private static func snapAdjustment(
        bounds: CGRect,
        canvasWidth: Double,
        canvasHeight: Double,
        tolerance: Double
    ) -> (x: Double, y: Double) {
        let actionX = canvasWidth * actionSafeInsetFraction
        let actionY = canvasHeight * actionSafeInsetFraction
        let titleX = canvasWidth * titleSafeInsetFraction
        let titleY = canvasHeight * titleSafeInsetFraction
        let horizontal = nearestAdjustment(
            [
                actionX - bounds.minX,
                (canvasWidth - actionX) - bounds.maxX,
                titleX - bounds.minX,
                (canvasWidth - titleX) - bounds.maxX,
                (canvasWidth / 2.0) - bounds.midX
            ],
            tolerance: tolerance
        )
        let vertical = nearestAdjustment(
            [
                actionY - bounds.minY,
                (canvasHeight - actionY) - bounds.maxY,
                titleY - bounds.minY,
                (canvasHeight - titleY) - bounds.maxY,
                (canvasHeight / 2.0) - bounds.midY
            ],
            tolerance: tolerance
        )
        return (horizontal, vertical)
    }

    private static func nearestAdjustment(_ values: [Double], tolerance: Double) -> Double {
        let nearest = values.min { abs($0) < abs($1) } ?? 0
        return abs(nearest) <= tolerance ? nearest : 0
    }

    fileprivate static func rotationDegrees(_ rotation: ClipRotation) -> Double {
        rotation.degrees.doubleValue + (Double(rotation.revolutions) * 360.0)
    }

    fileprivate static func transformedPoint(
        _ point: CGPoint,
        layout: CanvasTitleBoxLayout
    ) -> CGPoint {
        let transform = layout.clipTransform
        let canvasWidth = Double(layout.canvasSize.width)
        let canvasHeight = Double(layout.canvasSize.height)
        let sourceX = transform.flip.horizontal ? canvasWidth - point.x : point.x
        let sourceY = transform.flip.vertical ? canvasHeight - point.y : point.y
        let anchorX = transform.anchorPoint.x.doubleValue
        let anchorY = transform.anchorPoint.y.doubleValue
        let scaledX = (sourceX - anchorX) * transform.scale.x.doubleValue
        let scaledY = (sourceY - anchorY) * transform.scale.y.doubleValue
        let radians = rotationDegrees(transform.rotation) * .pi / 180.0
        let cosine = cos(radians)
        let sine = sin(radians)
        let rotatedX = (scaledX * cosine) - (scaledY * sine)
        let rotatedY = (scaledX * sine) + (scaledY * cosine)
        return CGPoint(
            x: anchorX + transform.position.x.doubleValue + rotatedX,
            y: anchorY + transform.position.y.doubleValue + rotatedY
        )
    }

    private static func nonzeroScale(_ value: Double) -> Double {
        if abs(value) > 0.000_001 {
            return value
        }
        return value < 0 ? -0.000_001 : 0.000_001
    }
}

private struct CanvasViewportMetrics {
    let scale: Double
    let rect: CGRect

    init(viewSize: CGSize, canvasSize: PixelDimensions) {
        let width = max(1.0, Double(canvasSize.width))
        let height = max(1.0, Double(canvasSize.height))
        scale = min(viewSize.width / width, viewSize.height / height)
        let fittedWidth = width * scale
        let fittedHeight = height * scale
        rect = CGRect(
            x: (viewSize.width - fittedWidth) / 2.0,
            y: (viewSize.height - fittedHeight) / 2.0,
            width: fittedWidth,
            height: fittedHeight
        )
    }
}

private struct CanvasTitleDisplayGeometry {
    let center: CGPoint
    let size: CGSize
    let rotationDegrees: Double

    init(layout: CanvasTitleBoxLayout, viewport: CanvasViewportMetrics) {
        let boxCenter = CGPoint(
            x: layout.box.origin.x.doubleValue + (layout.box.width.doubleValue / 2.0),
            y: layout.box.origin.y.doubleValue + (layout.box.height.doubleValue / 2.0)
        )
        let transformedCenter = CanvasTitlePositioning.transformedPoint(
            boxCenter,
            layout: layout
        )
        center = CGPoint(
            x: viewport.rect.minX + (transformedCenter.x * viewport.scale),
            y: viewport.rect.minY + (transformedCenter.y * viewport.scale)
        )
        size = CGSize(
            width: max(
                8,
                abs(layout.box.width.doubleValue * layout.clipTransform.scale.x.doubleValue)
                    * viewport.scale
            ),
            height: max(
                8,
                abs(layout.box.height.doubleValue * layout.clipTransform.scale.y.doubleValue)
                    * viewport.scale
            )
        )
        rotationDegrees = CanvasTitlePositioning.rotationDegrees(layout.clipTransform.rotation)
    }

}

struct CanvasTitleEditingOverlay: View {
    @ObservedObject var model: EditorAjarAppModel
    @FocusState private var focusedReference: CanvasTitleBoxReference?

    var body: some View {
        GeometryReader { geometry in
            if let canvasSize = model.canvasDimensions {
                let viewport = CanvasViewportMetrics(
                    viewSize: geometry.size,
                    canvasSize: canvasSize
                )
                canvasStack(viewport: viewport)
            }
        }
        // Pass title-box / guide AX children through; do not claim a group label that
        // would replace the program monitor's "Program monitor showing …" identity.
        .accessibilityElement(children: .contain)
    }

    private func canvasStack(viewport: CanvasViewportMetrics) -> some View {
        titleBoxesAndGuides(viewport: viewport)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .onChange(of: model.editingCanvasTitleBoxReference) { _, reference in
                restoreFocusAfterEditingEnds(reference)
            }
    }

    private func titleBoxesAndGuides(viewport: CanvasViewportMetrics) -> some View {
        // topLeading + per-box frame/offset: children do not expand to the ZStack size.
        ZStack(alignment: .topLeading) {
            if model.canvasSafeAreaGuidesVisible {
                CanvasSafeAreaGuides(viewport: viewport)
            }
            ForEach(model.visibleCanvasTitleBoxes) { layout in
                titleElement(layout: layout, viewport: viewport)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func restoreFocusAfterEditingEnds(_ reference: CanvasTitleBoxReference?) {
        guard reference == nil,
            let selectedReference = model.selectedCanvasTitleBoxReference
        else {
            return
        }
        DispatchQueue.main.async {
            focusedReference = selectedReference
        }
    }

    @ViewBuilder
    private func titleElement(
        layout: CanvasTitleBoxLayout,
        viewport: CanvasViewportMetrics
    ) -> some View {
        if model.editingCanvasTitleBoxReference == layout.reference {
            editingTitleElement(layout: layout, viewport: viewport)
        } else {
            idleTitleElement(layout: layout, viewport: viewport)
        }
    }

    private func editingTitleElement(
        layout: CanvasTitleBoxLayout,
        viewport: CanvasViewportMetrics
    ) -> some View {
        let display = CanvasTitleDisplayGeometry(layout: layout, viewport: viewport)
        let editor = CanvasTitleTextEditor(
            text: layout.box.text,
            style: layout.box.style,
            canvasScale: viewport.scale,
            accessibilityIdentifier: editorAccessibilityIdentifier(layout.reference),
            accessibilityLabel: accessibilityLabel(layout),
            onTextChange: { text in
                model.updateCanvasTitleText(text, reference: layout.reference)
            },
            onCommit: {
                model.endCanvasTitleTextEditing(for: layout.reference)
            },
            onMoveFocus: { reverse in
                _ = model.editAdjacentCanvasTitleBox(
                    from: layout.reference,
                    reverse: reverse
                )
            }
        )
        return positionedEditingEditor(editor, display: display)
            .id(layout.reference)
    }

    private func positionedEditingEditor(
        _ editor: CanvasTitleTextEditor,
        display: CanvasTitleDisplayGeometry
    ) -> some View {
        // Use offset (not position) so layout/hit/AX size stays the box, not the full canvas.
        editor
            .frame(width: display.size.width, height: display.size.height)
            .overlay(editingSelectionBorder)
            .rotationEffect(.degrees(display.rotationDegrees))
            .offset(CanvasTitleBoxPlacement.topLeftOffset(display: display, dragPreview: .zero))
    }

    private var editingSelectionBorder: some View {
        RoundedRectangle(cornerRadius: 3)
            .stroke(Color.accentColor, lineWidth: 2)
            .allowsHitTesting(false)
    }

    private func idleTitleElement(
        layout: CanvasTitleBoxLayout,
        viewport: CanvasViewportMetrics
    ) -> some View {
        CanvasTitleBoxElement(
            layout: layout,
            viewport: viewport,
            focusedReference: $focusedReference,
            isSelected: model.selectedCanvasTitleBoxReference == layout.reference,
            beginEditing: {
                _ = model.beginCanvasTitleTextEditing(layout.reference)
            },
            select: {
                _ = model.selectCanvasTitleBox(layout.reference)
            },
            drag: { translation in
                _ = model.dragCanvasTitleBox(
                    layout.reference,
                    translationX: translation.width,
                    translationY: translation.height,
                    canvasScale: viewport.scale
                )
            },
            nudge: { direction, largeStep in
                _ = model.nudgeCanvasTitleBox(
                    layout.reference,
                    direction: direction,
                    largeStep: largeStep
                )
            }
        )
    }

    private func accessibilityLabel(_ layout: CanvasTitleBoxLayout) -> String {
        "Title text box \(layout.boxIndex + 1), \(layout.clipName)"
    }

    private func editorAccessibilityIdentifier(_ reference: CanvasTitleBoxReference) -> String {
        "Canvas Title Editor \(reference.boxID.uuidString)"
    }
}

/// Shared placement: box-sized layout frame + offset (not `.position`, which expands hit/AX).
private enum CanvasTitleBoxPlacement {
    static func topLeftOffset(
        display: CanvasTitleDisplayGeometry,
        dragPreview: CGSize
    ) -> CGSize {
        CGSize(
            width: display.center.x - display.size.width / 2 + dragPreview.width,
            height: display.center.y - display.size.height / 2 + dragPreview.height
        )
    }
}

private struct CanvasTitleBoxElement: View {
    let layout: CanvasTitleBoxLayout
    let viewport: CanvasViewportMetrics
    let focusedReference: FocusState<CanvasTitleBoxReference?>.Binding
    let isSelected: Bool
    let beginEditing: () -> Void
    let select: () -> Void
    let drag: (CGSize) -> Void
    let nudge: (CanvasTitleNudgeDirection, Bool) -> Void

    @GestureState private var dragPreview = CGSize.zero

    var body: some View {
        let display = CanvasTitleDisplayGeometry(layout: layout, viewport: viewport)
        // Order: tight frame → interaction/AX → offset into place. Do not use `.position`,
        // which expands layout/hit/AX to the full parent and occludes the guides toggle.
        return chrome
            .frame(width: display.size.width, height: display.size.height)
            .contentShape(Rectangle())
            .rotationEffect(.degrees(display.rotationDegrees))
            .focusable(layout.isEditable)
            .focused(focusedReference, equals: layout.reference)
            .gesture(titleGesture)
            .onChange(of: focusedReference.wrappedValue) { _, reference in
                if reference == layout.reference {
                    select()
                }
            }
            .onKeyPress(.return, action: handleReturnKey)
            .onKeyPress(
                keys: [.leftArrow, .rightArrow, .upArrow, .downArrow],
                action: handleArrowKey
            )
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier(boxAccessibilityIdentifier)
            .accessibilityLabel(boxAccessibilityLabel)
            .accessibilityValue(accessibilityValue)
            .accessibilityHint(boxAccessibilityHint)
            .accessibilityAddTraits(layout.isEditable ? .isButton : [])
            .accessibilityAction {
                if layout.isEditable {
                    beginEditing()
                }
            }
            .accessibilityAction(named: "Edit") {
                if layout.isEditable {
                    beginEditing()
                }
            }
            .offset(
                CanvasTitleBoxPlacement.topLeftOffset(display: display, dragPreview: dragPreview)
            )
    }

    private var chrome: some View {
        let fillColor = Color.black.opacity(0.001)
        let strokeColor: Color = isSelected ? Color.accentColor : Color.white.opacity(0.62)
        let lineWidth: CGFloat = isSelected ? 2 : 1
        let strokeStyle = StrokeStyle(lineWidth: lineWidth, dash: [5, 3])
        return RoundedRectangle(cornerRadius: 3)
            .fill(fillColor)
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .stroke(strokeColor, style: strokeStyle)
            )
    }

    private var boxAccessibilityIdentifier: String {
        "Canvas Title Text Box \(layout.reference.boxID.uuidString)"
    }

    private var boxAccessibilityLabel: String {
        "Title text box \(layout.boxIndex + 1), \(layout.clipName)"
    }

    private var boxAccessibilityHint: String {
        if layout.isEditable {
            return "Press Return to edit. Drag or use arrow keys to move."
        }
        return "This title is on a locked track."
    }

    private func handleReturnKey() -> KeyPress.Result {
        guard layout.isEditable else {
            return .ignored
        }
        beginEditing()
        return .handled
    }

    private func handleArrowKey(_ keyPress: KeyPress) -> KeyPress.Result {
        guard layout.isEditable,
            let direction = nudgeDirection(for: keyPress.key)
        else {
            return .ignored
        }
        nudge(direction, keyPress.modifiers.contains(.shift))
        return .handled
    }

    private var titleGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($dragPreview) { value, state, _ in
                if gestureDistance(value.translation) >= 3 {
                    state = value.translation
                }
            }
            .onEnded { value in
                guard layout.isEditable else {
                    return
                }
                if gestureDistance(value.translation) < 3 {
                    focusedReference.wrappedValue = layout.reference
                    beginEditing()
                } else {
                    select()
                    drag(value.translation)
                }
            }
    }

    private var accessibilityValue: String {
        let text = layout.box.text.isEmpty ? "Empty text" : layout.box.text
        return "\(text), X \(formatted(layout.box.origin.x)), Y \(formatted(layout.box.origin.y))"
    }

    private func formatted(_ value: RationalValue) -> String {
        if value.denominator == 1 {
            return String(value.numerator)
        }
        let number = value.doubleValue
        if abs(number.rounded() - number) < 0.000_001 {
            return String(format: "%.0f", number)
        }
        return String(format: "%.2f", number)
    }

    private func gestureDistance(_ translation: CGSize) -> Double {
        hypot(translation.width, translation.height)
    }

    private func nudgeDirection(for key: KeyEquivalent) -> CanvasTitleNudgeDirection? {
        switch key {
        case .leftArrow:
            return .left
        case .rightArrow:
            return .right
        case .upArrow:
            return .up
        case .downArrow:
            return .down
        default:
            return nil
        }
    }
}

private struct CanvasSafeAreaGuides: View {
    let viewport: CanvasViewportMetrics

    var body: some View {
        guidesContent
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier("Canvas Safe Area Guides")
            .accessibilityLabel("Action-safe and title-safe guides")
    }

    private var guidesContent: some View {
        ZStack(alignment: .topLeading) {
            guideRectangle(
                insetFraction: CanvasTitlePositioning.actionSafeInsetFraction,
                color: .yellow,
                label: "Action Safe"
            )
            guideRectangle(
                insetFraction: CanvasTitlePositioning.titleSafeInsetFraction,
                color: .cyan,
                label: "Title Safe"
            )
        }
    }

    private func guideRectangle(
        insetFraction: Double,
        color: Color,
        label: String
    ) -> some View {
        let insetX = viewport.rect.width * insetFraction
        let insetY = viewport.rect.height * insetFraction
        let rect = viewport.rect.insetBy(dx: insetX, dy: insetY)
        return guideChrome(color: color, label: label)
            .frame(width: rect.width, height: rect.height)
            .offset(x: rect.minX, y: rect.minY)
    }

    private func guideChrome(color: Color, label: String) -> some View {
        let strokeStyle = StrokeStyle(lineWidth: 1, dash: [6, 4])
        return ZStack(alignment: .topLeading) {
            Rectangle()
                .stroke(color.opacity(0.9), style: strokeStyle)
            guideLabel(text: label, color: color)
        }
    }

    private func guideLabel(text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(3)
            .background(Color.black.opacity(0.64), in: RoundedRectangle(cornerRadius: 3))
            .padding(4)
            .accessibilityHidden(true)
    }
}

private struct CanvasTitleTextEditor: NSViewRepresentable {
    let text: String
    let style: TitleTextStyle
    let canvasScale: Double
    let accessibilityIdentifier: String
    let accessibilityLabel: String
    let onTextChange: (String) -> Void
    let onCommit: () -> Void
    let onMoveFocus: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> CanvasTitleNSTextView {
        let textView = CanvasTitleNSTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.drawsBackground = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = false
        textView.allowsUndo = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = true
        textView.insertionPointColor = .white
        textView.string = text
        textView.finishEditingAction = { [weak coordinator = context.coordinator, weak textView] in
            guard let coordinator, let textView else {
                return
            }
            coordinator.finishEditing(textView)
        }
        textView.requestsInitialFocus = true
        configure(textView)
        return textView
    }

    func updateNSView(_ textView: CanvasTitleNSTextView, context: Context) {
        context.coordinator.parent = self
        textView.finishEditingAction = { [weak coordinator = context.coordinator, weak textView] in
            guard let coordinator, let textView else {
                return
            }
            coordinator.finishEditing(textView)
        }
        if !textView.hasMarkedText() {
            configure(textView)
        }
        guard textView.string != text, !textView.hasMarkedText() else {
            return
        }

        let selection = textView.selectedRange()
        context.coordinator.isApplyingModelText = true
        textView.string = text
        let maximumLocation = (text as NSString).length
        textView.setSelectedRange(
            NSRange(location: min(selection.location, maximumLocation), length: 0)
        )
        context.coordinator.isApplyingModelText = false
    }

    private func configure(_ textView: CanvasTitleNSTextView) {
        let fontSize = max(8, style.fontSize.doubleValue * canvasScale)
        let baseFont =
            NSFont(name: style.fontFamily, size: fontSize)
            ?? NSFont(name: TitleSource.deterministicFontFamily, size: fontSize)
            ?? NSFont.systemFont(ofSize: fontSize)
        let resolvedFont = font(with: style.fontWeight, baseFont: baseFont, size: fontSize)
        let textColor = NSColor(
            red: style.color.red.doubleValue,
            green: style.color.green.doubleValue,
            blue: style.color.blue.doubleValue,
            alpha: 1
        )
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = style.leading.doubleValue * canvasScale
        paragraphStyle.alignment = textAlignment(style.alignment)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: resolvedFont,
            .foregroundColor: textColor,
            .kern: style.tracking.doubleValue * canvasScale,
            .paragraphStyle: paragraphStyle
        ]
        textView.font = resolvedFont
        textView.textColor = textColor
        textView.alignment = paragraphStyle.alignment
        textView.defaultParagraphStyle = paragraphStyle
        textView.typingAttributes = attributes
        textView.textStorage?.setAttributes(
            attributes,
            range: NSRange(location: 0, length: (textView.string as NSString).length)
        )
        textView.backgroundColor = NSColor.black.withAlphaComponent(0.68)
        textView.setAccessibilityIdentifier(accessibilityIdentifier)
        textView.setAccessibilityLabel(accessibilityLabel)
        textView.setAccessibilityHelp(
            "Edit title text. Press Escape or Command-Return to finish. Press Tab for the next title box."
        )
    }

    private func font(with weight: TitleFontWeight, baseFont: NSFont, size: Double) -> NSFont {
        let systemWeight: NSFont.Weight
        switch weight {
        case .ultraLight:
            systemWeight = .ultraLight
        case .thin:
            systemWeight = .thin
        case .light:
            systemWeight = .light
        case .regular:
            return baseFont
        case .medium:
            systemWeight = .medium
        case .semibold:
            systemWeight = .semibold
        case .bold:
            systemWeight = .bold
        case .heavy:
            systemWeight = .heavy
        case .black:
            systemWeight = .black
        }
        let descriptor = baseFont.fontDescriptor.addingAttributes([
            .traits: [NSFontDescriptor.TraitKey.weight: systemWeight]
        ])
        return NSFont(descriptor: descriptor, size: size) ?? baseFont
    }

    private func textAlignment(_ alignment: TitleTextAlignment) -> NSTextAlignment {
        switch alignment {
        case .left:
            return .left
        case .center:
            return .center
        case .right:
            return .right
        case .justified:
            return .justified
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CanvasTitleTextEditor
        var isApplyingModelText = false
        private var isFinishing = false

        init(parent: CanvasTitleTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            // Adversarial review (FR-TXT-003 / #187): skip while IME marked text is
            // active — same contract as updateNSView. Intermediate compositions must
            // not push setTitleTextBox; the commit arrives when composition ends and
            // textDidChange fires again with hasMarkedText() == false. Full
            // setMarkedText simulation is not hosted in EditorAjarAppModelTests.
            guard !isApplyingModelText,
                let textView = notification.object as? NSTextView,
                !textView.hasMarkedText()
            else {
                return
            }
            parent.onTextChange(textView.string)
        }

        func textDidEndEditing(_ notification: Notification) {
            guard !isFinishing else {
                return
            }
            isFinishing = true
            DispatchQueue.main.async {
                self.parent.onCommit()
            }
        }

        func textView(
            _ textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            switch NSStringFromSelector(commandSelector) {
            case "cancelOperation:":
                finishEditing(textView)
                return true
            case "insertTab:":
                moveFocus(from: textView, reverse: false)
                return true
            case "insertBacktab:":
                moveFocus(from: textView, reverse: true)
                return true
            default:
                return false
            }
        }

        func finishEditing(_ textView: NSTextView) {
            guard !isFinishing else {
                return
            }
            isFinishing = true
            textView.window?.makeFirstResponder(nil)
            DispatchQueue.main.async {
                self.parent.onCommit()
            }
        }

        private func moveFocus(from textView: NSTextView, reverse: Bool) {
            guard !isFinishing else {
                return
            }
            isFinishing = true
            textView.window?.makeFirstResponder(nil)
            DispatchQueue.main.async {
                self.parent.onMoveFocus(reverse)
            }
        }
    }
}

private final class CanvasTitleNSTextView: NSTextView {
    var finishEditingAction: (() -> Void)?
    var requestsInitialFocus = false
    private var didRequestInitialFocus = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard requestsInitialFocus, !didRequestInitialFocus, window != nil else {
            return
        }
        didRequestInitialFocus = true
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else {
                return
            }
            window.makeFirstResponder(self)
            setSelectedRange(NSRange(location: (string as NSString).length, length: 0))
        }
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if isReturn, modifiers.contains(.command) {
            finishEditingAction?()
            return
        }
        super.keyDown(with: event)
    }
}
