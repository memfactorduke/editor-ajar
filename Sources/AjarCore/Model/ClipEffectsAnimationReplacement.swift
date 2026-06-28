// SPDX-License-Identifier: GPL-3.0-or-later

extension AnimatableClipEffects {
    /// Returns keyframable effects with replacement static values for any changed effect slots.
    public func replacingChangedEffects(
        from oldEffects: ClipEffects,
        to newEffects: ClipEffects
    ) -> AnimatableClipEffects {
        var effects = self
        if oldEffects.chromaKey != newEffects.chromaKey {
            effects = effects.replacing(chromaKey: newEffects.chromaKey)
        }
        if oldEffects.lumaKey != newEffects.lumaKey {
            effects = effects.replacing(lumaKey: newEffects.lumaKey)
        }
        if oldEffects.colorCorrection != newEffects.colorCorrection {
            effects = effects.replacing(colorCorrection: newEffects.colorCorrection)
        }
        if oldEffects.masks != newEffects.masks {
            effects = effects.replacing(masks: newEffects.masks)
        }
        return effects
    }

    /// Returns effects with replacement chroma-key animation while preserving other slots.
    public func replacing(chromaKey: ClipChromaKeySettings) -> AnimatableClipEffects {
        AnimatableClipEffects(
            chromaKey: .constant(chromaKey),
            lumaKey: lumaKey,
            colorCorrection: colorCorrection,
            masks: masks
        )
    }

    /// Returns effects with replacement luma-key animation while preserving other slots.
    public func replacing(lumaKey: ClipLumaKeySettings) -> AnimatableClipEffects {
        AnimatableClipEffects(
            chromaKey: chromaKey,
            lumaKey: .constant(lumaKey),
            colorCorrection: colorCorrection,
            masks: masks
        )
    }

    /// Returns effects with replacement color-correction animation while preserving other slots.
    public func replacing(colorCorrection: ClipColorCorrection) -> AnimatableClipEffects {
        AnimatableClipEffects(
            chromaKey: chromaKey,
            lumaKey: lumaKey,
            colorCorrection: .constant(colorCorrection),
            masks: masks
        )
    }

    /// Returns effects with replacement mask animations while preserving other slots.
    public func replacing(masks: [ClipMask]) -> AnimatableClipEffects {
        AnimatableClipEffects(
            chromaKey: chromaKey,
            lumaKey: lumaKey,
            colorCorrection: colorCorrection,
            masks: masks.map(AnimatableClipMask.constant)
        )
    }
}
