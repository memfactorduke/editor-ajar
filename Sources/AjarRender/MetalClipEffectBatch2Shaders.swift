// SPDX-License-Identifier: GPL-3.0-or-later

/// FR-FX-002 batch-2 fragments, appended after the shared effect helpers and generated layouts.
enum MetalClipEffectBatch2Shaders {
    static let source = """

        // MARK: - FR-FX-002 library effect nodes (batch 2)

        // Linear-working-space vignette. RGB math is performed straight, then repremultiplied;
        // alpha is unchanged and transparent pixels remain zero RGB.
        fragment float4 ajar_vignette_fragment(
            AjarVertexOut in [[stage_in]],
            texture2d<float> sourceTexture [[texture(0)]],
            constant AjarVignetteUniforms &uniforms [[buffer(0)]]
        ) {
            constexpr sampler linearSampler(address::clamp_to_edge, filter::linear);
            float4 sourcePremult = sourceTexture.sample(linearSampler, in.uv);
            float alpha = saturate(sourcePremult.a);
            float amount = saturate(uniforms.amount);
            if (amount < 0.001 || alpha <= 0.00001) {
                return sourcePremult;
            }

            float aspect = float(sourceTexture.get_width())
                / max(float(sourceTexture.get_height()), 1.0);
            float2 centered = in.uv - 0.5;
            centered.x *= aspect;
            float cornerDistance = length(float2(0.5 * aspect, 0.5));
            float normalizedDistance = length(centered) / max(cornerDistance, 0.00001);
            float radius = saturate(uniforms.radius);
            float softness = saturate(uniforms.softness);
            float edge = softness <= 0.00001
                ? (normalizedDistance >= radius ? 1.0 : 0.0)
                : smoothstep(radius, radius + softness, normalizedDistance);
            float3 straight = ajar_effect_unpremultiply(sourcePremult);
            float3 adjusted = straight * max(1.0 - (amount * edge), 0.0);
            return float4(max(adjusted, float3(0.0)) * alpha, alpha);
        }

        // Mirror is a coordinate fold: horizontal folds x, vertical folds y, quad folds both.
        // Sampling moves premultiplied RGBA together, preserving the texture contract.
        fragment float4 ajar_mirror_fragment(
            AjarVertexOut in [[stage_in]],
            texture2d<float> sourceTexture [[texture(0)]],
            constant AjarMirrorUniforms &uniforms [[buffer(0)]]
        ) {
            constexpr sampler linearSampler(address::clamp_to_edge, filter::linear);
            int axisMode = clamp(int(round(uniforms.axisMode)), 0, 2);
            float2 uv = in.uv;
            if (axisMode == 0 || axisMode == 2) {
                uv.x = min(uv.x, 1.0 - uv.x) * 2.0;
            }
            if (axisMode == 1 || axisMode == 2) {
                uv.y = min(uv.y, 1.0 - uv.y) * 2.0;
            }
            return sourceTexture.sample(linearSampler, saturate(uv));
        }

        // Pixelate by sampling each source-pixel cell at its clamped center.
        fragment float4 ajar_mosaic_fragment(
            AjarVertexOut in [[stage_in]],
            texture2d<float> sourceTexture [[texture(0)]],
            constant AjarMosaicUniforms &uniforms [[buffer(0)]]
        ) {
            constexpr sampler nearestSampler(address::clamp_to_edge, filter::nearest);
            float requestedCell = max(round(uniforms.cellSizePx), 1.0);
            if (requestedCell <= 1.0) {
                return sourceTexture.sample(nearestSampler, in.uv);
            }
            float2 dimensions = float2(
                float(sourceTexture.get_width()),
                float(sourceTexture.get_height())
            );
            float2 cellSize = min(float2(requestedCell), dimensions);
            float2 pixel = min(in.uv * dimensions, dimensions - 0.5);
            float2 cellOrigin = floor(pixel / cellSize) * cellSize;
            float2 samplePixel = min(cellOrigin + (cellSize * 0.5), dimensions - 0.5);
            return sourceTexture.sample(nearestSampler, samplePixel / dimensions);
        }

        // Straight linear RGB order: brightness, contrast about 18% gray, tint, saturation.
        fragment float4 ajar_color_adjust_fragment(
            AjarVertexOut in [[stage_in]],
            texture2d<float> sourceTexture [[texture(0)]],
            constant AjarColorAdjustUniforms &uniforms [[buffer(0)]]
        ) {
            constexpr sampler linearSampler(address::clamp_to_edge, filter::linear);
            float4 sourcePremult = sourceTexture.sample(linearSampler, in.uv);
            float alpha = saturate(sourcePremult.a);
            if (alpha <= 0.00001) {
                return float4(0.0);
            }
            float brightness = clamp(uniforms.brightness, -1.0, 1.0);
            float contrast = clamp(uniforms.contrast, 0.0, 4.0);
            float saturation = clamp(uniforms.saturation, 0.0, 4.0);
            float tint = clamp(uniforms.tint, -1.0, 1.0);
            float3 result = max(ajar_effect_unpremultiply(sourcePremult) + brightness, float3(0.0));
            result = max(((result - 0.18) * contrast) + 0.18, float3(0.0));
            float magenta = max(tint, 0.0);
            float green = max(-tint, 0.0);
            float3 tintScale = float3(
                1.0 + (magenta * 0.08),
                1.0 + (green * 0.10) - (magenta * 0.08),
                1.0 + (magenta * 0.08)
            );
            result *= max(tintScale, float3(0.0));
            constexpr float3 lumaWeights = float3(0.2126, 0.7152, 0.0722);
            float luma = dot(result, lumaWeights);
            result = max(mix(float3(luma), result, saturation), float3(0.0));
            return float4(result * alpha, alpha);
        }

        // Posterize straight linear RGB without clipping HDR headroom; alpha is unchanged.
        fragment float4 ajar_posterize_fragment(
            AjarVertexOut in [[stage_in]],
            texture2d<float> sourceTexture [[texture(0)]],
            constant AjarPosterizeUniforms &uniforms [[buffer(0)]]
        ) {
            constexpr sampler linearSampler(address::clamp_to_edge, filter::linear);
            float4 sourcePremult = sourceTexture.sample(linearSampler, in.uv);
            float alpha = saturate(sourcePremult.a);
            float levels = clamp(round(uniforms.levels), 2.0, 256.0);
            if (levels >= 255.5 || alpha <= 0.00001) {
                return sourcePremult;
            }
            float steps = levels - 1.0;
            float3 straight = max(ajar_effect_unpremultiply(sourcePremult), float3(0.0));
            float3 quantized = round(straight * steps) / steps;
            return float4(max(quantized, float3(0.0)) * alpha, alpha);
        }

        // Invert straight RGB around linear white (1.0), then restore premultiplication.
        fragment float4 ajar_invert_fragment(
            AjarVertexOut in [[stage_in]],
            texture2d<float> sourceTexture [[texture(0)]],
            constant AjarInvertUniforms &uniforms [[buffer(0)]]
        ) {
            constexpr sampler linearSampler(address::clamp_to_edge, filter::linear);
            float4 sourcePremult = sourceTexture.sample(linearSampler, in.uv);
            float alpha = saturate(sourcePremult.a);
            if (alpha <= 0.00001) {
                return float4(0.0);
            }
            float3 straight = ajar_effect_unpremultiply(sourcePremult);
            float3 inverted = max(float3(max(uniforms.whitePoint, 0.0)) - straight, float3(0.0));
            return float4(inverted * alpha, alpha);
        }
        """
}
