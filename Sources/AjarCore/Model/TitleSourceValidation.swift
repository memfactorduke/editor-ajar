// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

extension TitleSource {
    /// Returns the first typed validation error, or `nil` when the source is valid.
    public func validate() -> TitleSourceValidationError? {
        var seenIDs = Set<UUID>()
        for box in boxes {
            if !seenIDs.insert(box.id).inserted {
                return .duplicateTextBoxID(box.id)
            }
            if let error = validationError(for: box) {
                return error
            }
        }
        return nil
    }

    private func validationError(for box: TitleTextBox) -> TitleSourceValidationError? {
        let family = box.style.fontFamily.trimmingCharacters(in: .whitespacesAndNewlines)
        if family.isEmpty {
            return .emptyFontFamily
        }
        if box.width.numerator <= 0 || box.height.numerator <= 0 {
            return .nonPositiveBoxSize(width: box.width, height: box.height)
        }
        if let error = baseStyleError(box.style) {
            return error
        }
        if let stroke = box.style.stroke, let error = strokeError(stroke) {
            return error
        }
        if let shadow = box.style.dropShadow, let error = dropShadowError(shadow) {
            return error
        }
        if let background = box.backgroundBox, let error = backgroundError(background) {
            return error
        }
        if let gradient = box.style.gradientFill, let error = gradientError(gradient) {
            return error
        }
        return nil
    }

    private func baseStyleError(_ style: TitleTextStyle) -> TitleSourceValidationError? {
        if let error = rangeError(
            style.fontSize,
            minimum: Self.minimumFontSize,
            maximum: Self.maximumFontSize,
            as: { .fontSizeOutOfRange(value: $0, minimum: $1, maximum: $2) }
        ) {
            return error
        }
        if let error = rangeError(
            style.tracking,
            minimum: Self.minimumTracking,
            maximum: Self.maximumTracking,
            as: { .trackingOutOfRange(value: $0, minimum: $1, maximum: $2) }
        ) {
            return error
        }
        if let error = rangeError(
            style.leading,
            minimum: Self.minimumLeading,
            maximum: Self.maximumLeading,
            as: { .leadingOutOfRange(value: $0, minimum: $1, maximum: $2) }
        ) {
            return error
        }
        return colorError(style.color)
    }

    private func strokeError(_ stroke: TitleStrokeStyle) -> TitleSourceValidationError? {
        if let error = rangeError(
            stroke.width,
            minimum: Self.minimumStrokeWidth,
            maximum: Self.maximumStrokeWidth,
            as: { .strokeWidthOutOfRange(value: $0, minimum: $1, maximum: $2) }
        ) {
            return error
        }
        return colorError(stroke.color)
    }

    private func dropShadowError(
        _ shadow: TitleDropShadowStyle
    ) -> TitleSourceValidationError? {
        if let error = shadowOffsetError(shadow.offsetX, axis: .x) {
            return error
        }
        if let error = shadowOffsetError(shadow.offsetY, axis: .y) {
            return error
        }
        if let error = rangeError(
            shadow.blurRadius,
            minimum: .zero,
            maximum: Self.maximumDropShadowBlurRadius,
            as: { .dropShadowBlurRadiusOutOfRange(value: $0, minimum: $1, maximum: $2) }
        ) {
            return error
        }
        if let error = colorError(shadow.color) {
            return error
        }
        return opacityError(shadow.opacity, component: .dropShadow)
    }

    private func shadowOffsetError(
        _ value: RationalValue,
        axis: TitleShadowOffsetAxis
    ) -> TitleSourceValidationError? {
        rangeError(
            value,
            minimum: Self.minimumDropShadowOffset,
            maximum: Self.maximumDropShadowOffset,
            as: {
                .dropShadowOffsetOutOfRange(
                    axis: axis,
                    value: $0,
                    minimum: $1,
                    maximum: $2
                )
            }
        )
    }

    private func backgroundError(
        _ background: TitleBackgroundBoxStyle
    ) -> TitleSourceValidationError? {
        if let error = rangeError(
            background.padding,
            minimum: .zero,
            maximum: Self.maximumBackgroundPadding,
            as: { .backgroundPaddingOutOfRange(value: $0, minimum: $1, maximum: $2) }
        ) {
            return error
        }
        if let error = rangeError(
            background.cornerRadius,
            minimum: .zero,
            maximum: Self.maximumBackgroundCornerRadius,
            as: { .backgroundCornerRadiusOutOfRange(value: $0, minimum: $1, maximum: $2) }
        ) {
            return error
        }
        if let error = colorError(background.fillColor) {
            return error
        }
        return opacityError(background.opacity, component: .backgroundBox)
    }

    private func gradientError(
        _ gradient: TitleLinearGradientFill
    ) -> TitleSourceValidationError? {
        if let error = colorError(gradient.startColor) ?? colorError(gradient.endColor) {
            return error
        }
        return rangeError(
            gradient.angleDegrees,
            minimum: Self.minimumGradientAngle,
            maximum: Self.maximumGradientAngle,
            as: { .gradientAngleOutOfRange(value: $0, minimum: $1, maximum: $2) }
        )
    }

    private func opacityError(
        _ value: RationalValue,
        component: TitleStyleOpacityComponent
    ) -> TitleSourceValidationError? {
        if value.doubleValue < 0 || value.doubleValue > 1 {
            return .styleOpacityOutOfRange(component: component, value: value)
        }
        return nil
    }

    private func rangeError(
        _ value: RationalValue,
        minimum: RationalValue,
        maximum: RationalValue,
        as make: (RationalValue, RationalValue, RationalValue) -> TitleSourceValidationError
    ) -> TitleSourceValidationError? {
        if value.doubleValue < minimum.doubleValue || value.doubleValue > maximum.doubleValue {
            return make(value, minimum, maximum)
        }
        return nil
    }

    private func colorError(_ color: ClipRGBColor) -> TitleSourceValidationError? {
        colorChannelError(color.red, channel: .red)
            ?? colorChannelError(color.green, channel: .green)
            ?? colorChannelError(color.blue, channel: .blue)
    }

    private func colorChannelError(
        _ value: RationalValue,
        channel: ClipColorChannel
    ) -> TitleSourceValidationError? {
        if value.doubleValue < 0 || value.doubleValue > 1 {
            return .colorChannelOutOfRange(channel: channel, value: value)
        }
        return nil
    }
}
