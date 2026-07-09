// SPDX-License-Identifier: GPL-3.0-or-later

/// FR-FX-002 library effect fragment shaders (ADR-0016).
///
/// Appended to the shared Metal library in `MetalRenderExecutor` (same `metal_stdlib` /
/// fullscreen vertex). Effects stay GPU-resident — no CPU readback (FR-FX-007 / ADR-0012).
///
/// Uniform struct declarations are **generated** from `MetalEffectUniformLayout` so MSL
/// field order and the Swift pack path cannot drift.
enum MetalClipEffectStackShaders {
    /// Shader source fragment concatenated after the core composite library.
    static let source = """

        // MARK: - FR-FX-002 library effect nodes

        // Uniform layouts: single source of truth is MetalEffectUniformLayout (do not hand-edit).
        \(MetalEffectUniformLayout.allMSLStructDeclarations)

        static float4 ajar_effect_sample(texture2d<float> tex, sampler samp, float2 uv) {
            return tex.sample(samp, saturate(uv));
        }

        // Separable Gaussian: 9-tap binomial weights along `direction` (two-pass FR-FX-002).
        fragment float4 ajar_gaussian_blur_fragment(
            AjarVertexOut in [[stage_in]],
            texture2d<float> sourceTexture [[texture(0)]],
            constant AjarSeparableBlurUniforms &uniforms [[buffer(0)]]
        ) {
            constexpr sampler linearSampler(
                address::clamp_to_edge,
                filter::linear
            );
            float radius = max(uniforms.radius, 0.0);
            if (radius < 0.001) {
                return sourceTexture.sample(linearSampler, in.uv);
            }

            float2 stepUV = uniforms.texelSize * uniforms.direction * radius / 4.0;
            constexpr float weights[5] = {
                0.2270270270,
                0.1945945946,
                0.1216216216,
                0.0540540541,
                0.0162162162
            };

            float4 color = sourceTexture.sample(linearSampler, in.uv) * weights[0];
            for (int i = 1; i < 5; ++i) {
                float2 offset = stepUV * float(i);
                color += ajar_effect_sample(sourceTexture, linearSampler, in.uv + offset)
                    * weights[i];
                color += ajar_effect_sample(sourceTexture, linearSampler, in.uv - offset)
                    * weights[i];
            }
            return color;
        }

        // Separable box blur: uniform average along `direction`.
        fragment float4 ajar_box_blur_fragment(
            AjarVertexOut in [[stage_in]],
            texture2d<float> sourceTexture [[texture(0)]],
            constant AjarSeparableBlurUniforms &uniforms [[buffer(0)]]
        ) {
            constexpr sampler linearSampler(
                address::clamp_to_edge,
                filter::linear
            );
            float radius = max(uniforms.radius, 0.0);
            if (radius < 0.001) {
                return sourceTexture.sample(linearSampler, in.uv);
            }

            int taps = max(int(ceil(radius)) * 2 + 1, 1);
            taps = min(taps, 33);
            float halfSpan = float(taps - 1) * 0.5;
            float2 stepUV = uniforms.texelSize * uniforms.direction;
            float4 color = float4(0.0);
            for (int i = 0; i < taps; ++i) {
                float offset = float(i) - halfSpan;
                color += ajar_effect_sample(
                    sourceTexture,
                    linearSampler,
                    in.uv + stepUV * offset
                );
            }
            return color / float(taps);
        }

        // Zoom / radial blur: multi-sample along the ray toward `center`.
        // amount 0...1 scales max pull: at 1.0 the far samples sit at 65% of the
        // center→pixel radius (1 - 0.35), a mild directional streak (ADR-0016 library intent).
        // Continuous UV scales — no texel-grid quantisation that could collapse to identity.
        fragment float4 ajar_zoom_blur_fragment(
            AjarVertexOut in [[stage_in]],
            texture2d<float> sourceTexture [[texture(0)]],
            constant AjarZoomBlurUniforms &uniforms [[buffer(0)]]
        ) {
            constexpr sampler linearSampler(
                address::clamp_to_edge,
                filter::linear
            );
            float amount = saturate(uniforms.amount);
            if (amount < 0.001) {
                return sourceTexture.sample(linearSampler, in.uv);
            }

            float2 center = saturate(uniforms.center);
            float2 delta = in.uv - center;
            constexpr int samples = 12;
            float4 color = float4(0.0);
            for (int i = 0; i < samples; ++i) {
                float t = float(i) / float(samples - 1);
                float scale = 1.0 - (amount * 0.35 * t);
                color += ajar_effect_sample(
                    sourceTexture,
                    linearSampler,
                    center + delta * scale
                );
            }
            return color / float(samples);
        }

        // Premultiplied-safe unpremultiply (matches composite ajar_unpremultiply).
        static float3 ajar_effect_unpremultiply(float4 color) {
            if (color.a <= 0.00001) {
                return float3(0.0);
            }
            return color.rgb / color.a;
        }

        // Unsharp-mask style sharpen: source + amount * (source - neighborhood blur).
        // Operates on straight RGB (unpremultiply → effect → repremultiply) so RGB never
        // exceeds alpha and transparent pixels stay RGB=0 (premultiplied contract).
        // Uniforms: AjarSharpenUniforms from MetalEffectUniformLayout.sharpen
        // (amount, radiusPx, pad, pad) — texel size from the texture.
        fragment float4 ajar_sharpen_fragment(
            AjarVertexOut in [[stage_in]],
            texture2d<float> sourceTexture [[texture(0)]],
            constant AjarSharpenUniforms &uniforms [[buffer(0)]]
        ) {
            constexpr sampler linearSampler(
                address::clamp_to_edge,
                filter::linear
            );
            float amount = saturate(uniforms.amount);
            float radius = max(uniforms.radiusPx, 0.0);
            float4 centerPremult = sourceTexture.sample(linearSampler, in.uv);
            float alpha = saturate(centerPremult.a);
            if (amount < 0.001 || radius < 0.001 || alpha <= 0.00001) {
                return centerPremult;
            }

            float3 center = ajar_effect_unpremultiply(centerPremult);
            float2 texelSize = float2(
                1.0 / float(sourceTexture.get_width()),
                1.0 / float(sourceTexture.get_height())
            );
            float2 stepUV = texelSize * radius;
            float3 blur =
                (ajar_effect_unpremultiply(ajar_effect_sample(
                    sourceTexture, linearSampler, in.uv + float2(-stepUV.x, 0.0)
                ))
                    + ajar_effect_unpremultiply(ajar_effect_sample(
                        sourceTexture, linearSampler, in.uv + float2(stepUV.x, 0.0)
                    ))
                    + ajar_effect_unpremultiply(ajar_effect_sample(
                        sourceTexture, linearSampler, in.uv + float2(0.0, -stepUV.y)
                    ))
                    + ajar_effect_unpremultiply(ajar_effect_sample(
                        sourceTexture, linearSampler, in.uv + float2(0.0, stepUV.y)
                    ))
                    + center)
                * 0.2;
            float3 highPass = center - blur;
            float3 sharpened = center + highPass * amount;
            return float4(max(sharpened, float3(0.0)) * alpha, alpha);
        }

        // Glow combine: soft additive lift of the pre-blurred field onto source
        // (blur radius applied in the preceding separable Gaussian pass; amount 0...1).
        // Straight-RGB math then repremultiply (same premultiplied contract as sharpen).
        fragment float4 ajar_glow_combine_fragment(
            AjarVertexOut in [[stage_in]],
            texture2d<float> sourceTexture [[texture(0)]],
            texture2d<float> blurredTexture [[texture(1)]],
            constant AjarGlowCombineUniforms &uniforms [[buffer(0)]]
        ) {
            constexpr sampler linearSampler(
                address::clamp_to_edge,
                filter::linear
            );
            float amount = saturate(uniforms.amount);
            float4 sourcePremult = sourceTexture.sample(linearSampler, in.uv);
            float alpha = saturate(sourcePremult.a);
            if (amount < 0.001) {
                return sourcePremult;
            }
            if (alpha <= 0.00001) {
                return float4(0.0);
            }
            float3 source = ajar_effect_unpremultiply(sourcePremult);
            float3 blurred = ajar_effect_unpremultiply(
                blurredTexture.sample(linearSampler, in.uv)
            );
            float3 glowRGB = source + (blurred * amount);
            return float4(max(glowRGB, float3(0.0)) * alpha, alpha);
        }

        // Identity passthrough for the placeholder kind.
        fragment float4 ajar_effect_passthrough_fragment(
            AjarVertexOut in [[stage_in]],
            texture2d<float> sourceTexture [[texture(0)]]
        ) {
            constexpr sampler linearSampler(
                address::clamp_to_edge,
                filter::linear
            );
            return sourceTexture.sample(linearSampler, in.uv);
        }
        """
}
