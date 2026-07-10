// SPDX-License-Identifier: GPL-3.0-or-later

/// FR-FX-001 two-input video transition fragment shaders (ADR-0016 §5).
///
/// Appended to the shared Metal library **after** `MetalClipEffectStackShaders`, which already
/// injects every layout in `MetalEffectUniformLayout.all` (including `videoTransition` →
/// `AjarVideoTransitionUniforms`). Do **not** re-emit that struct here — a second declaration
/// redefines the type and fails Metal library compile.
///
/// Field order read by `ajar_video_transition_fragment` must match the layout pack order:
/// `progress`, `kindCode`, `directionCode`, `padding0`, `dipColor`.
enum MetalVideoTransitionShaders {
    /// Shader source fragment concatenated after the core + effect libraries.
    static let source = """

        // MARK: - FR-FX-001 video transitions
        // AjarVideoTransitionUniforms: generated once via MetalEffectUniformLayout.all
        // (MetalClipEffectStackShaders.allMSLStructDeclarations) — single source of truth.

        static float4 ajar_transition_unpremultiply(float4 color) {
            if (color.a <= 0.00001) {
                return float4(0.0, 0.0, 0.0, 0.0);
            }
            return float4(color.rgb / color.a, color.a);
        }

        static float4 ajar_transition_premultiply(float3 rgb, float alpha) {
            return float4(rgb * alpha, alpha);
        }

        // Premultiply-correct linear cross-dissolve: lerp straight RGB, then re-premultiply.
        static float4 ajar_transition_cross_dissolve(float4 a, float4 b, float t) {
            float4 sa = ajar_transition_unpremultiply(a);
            float4 sb = ajar_transition_unpremultiply(b);
            float3 rgb = mix(sa.rgb, sb.rgb, t);
            float alpha = mix(sa.a, sb.a, t);
            return ajar_transition_premultiply(rgb, alpha);
        }

        static float2 ajar_transition_push_offset(float directionCode, float t) {
            // Outgoing offset for push: slides out in the named direction.
            if (directionCode < 0.5) { return float2(-t, 0.0); }       // left
            if (directionCode < 1.5) { return float2(t, 0.0); }        // right
            if (directionCode < 2.5) { return float2(0.0, -t); }       // top
            return float2(0.0, t);                                     // bottom
        }

        static float ajar_transition_wipe_mask(float2 uv, float directionCode, float t) {
            // Soft-edged wipe mask: 1 = fully incoming, 0 = fully outgoing.
            float edge = 0.0;
            if (directionCode < 0.5) {          // left → right
                edge = uv.x;
            } else if (directionCode < 1.5) {   // right → left
                edge = 1.0 - uv.x;
            } else if (directionCode < 2.5) {   // top → bottom
                edge = uv.y;
            } else if (directionCode < 3.5) {   // bottom → top
                edge = 1.0 - uv.y;
            } else if (directionCode < 4.5) {   // TL
                edge = (uv.x + uv.y) * 0.5;
            } else if (directionCode < 5.5) {   // TR
                edge = ((1.0 - uv.x) + uv.y) * 0.5;
            } else if (directionCode < 6.5) {   // BL
                edge = (uv.x + (1.0 - uv.y)) * 0.5;
            } else {                            // BR
                edge = ((1.0 - uv.x) + (1.0 - uv.y)) * 0.5;
            }
            float softness = 0.02;
            return smoothstep(t - softness, t + softness, edge);
        }

        static float4 ajar_transition_sample(
            texture2d<float> tex,
            sampler samp,
            float2 uv
        ) {
            if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
                return float4(0.0);
            }
            return tex.sample(samp, uv);
        }

        fragment float4 ajar_video_transition_fragment(
            AjarVertexOut in [[stage_in]],
            texture2d<float> outgoingTexture [[texture(0)]],
            texture2d<float> incomingTexture [[texture(1)]],
            constant AjarVideoTransitionUniforms &uniforms [[buffer(0)]]
        ) {
            constexpr sampler linearSampler(
                address::clamp_to_edge,
                filter::linear
            );
            float t = saturate(uniforms.progress);
            float kind = uniforms.kindCode;
            float dir = uniforms.directionCode;
            float2 uv = in.uv;

            // crossDissolve (0)
            if (kind < 0.5) {
                float4 a = outgoingTexture.sample(linearSampler, uv);
                float4 b = incomingTexture.sample(linearSampler, uv);
                return ajar_transition_cross_dissolve(a, b, t);
            }

            // dipToColor (1) and fade (2): A → color → B
            if (kind < 2.5) {
                float4 a = outgoingTexture.sample(linearSampler, uv);
                float4 b = incomingTexture.sample(linearSampler, uv);
                float4 dip = ajar_transition_premultiply(uniforms.dipColor.rgb, 1.0);
                if (kind >= 1.5) {
                    // fade always dips through black regardless of dipColor.
                    dip = float4(0.0, 0.0, 0.0, 1.0);
                }
                if (t < 0.5) {
                    float local = t * 2.0;
                    return ajar_transition_cross_dissolve(a, dip, local);
                }
                float local = (t - 0.5) * 2.0;
                return ajar_transition_cross_dissolve(dip, b, local);
            }

            // push (3): both frames slide
            if (kind < 3.5) {
                float2 outOff = ajar_transition_push_offset(dir, t);
                float2 inOff = ajar_transition_push_offset(dir, t - 1.0);
                float4 a = ajar_transition_sample(outgoingTexture, linearSampler, uv + outOff);
                float4 b = ajar_transition_sample(incomingTexture, linearSampler, uv + inOff);
                // Prefer the sample that still covers the pixel (premultiplied coverage).
                if (b.a > 0.001 && a.a > 0.001) {
                    return ajar_transition_cross_dissolve(a, b, 0.5);
                }
                return b.a > 0.001 ? b : a;
            }

            // slide (4): incoming slides over static outgoing
            if (kind < 4.5) {
                float2 inOff = ajar_transition_push_offset(dir, t - 1.0);
                float4 a = outgoingTexture.sample(linearSampler, uv);
                float4 b = ajar_transition_sample(incomingTexture, linearSampler, uv + inOff);
                if (b.a > 0.001) {
                    return b;
                }
                return a;
            }

            // wipe (5)
            if (kind < 5.5) {
                float4 a = outgoingTexture.sample(linearSampler, uv);
                float4 b = incomingTexture.sample(linearSampler, uv);
                // mask 0 at start (outgoing), 1 at end (incoming): invert wipe edge vs progress
                float mask = 1.0 - ajar_transition_wipe_mask(uv, dir, t);
                return ajar_transition_cross_dissolve(a, b, mask);
            }

            // zoom (6): outgoing scales out, incoming scales in
            float outScale = 1.0 + t * 0.5;
            float inScale = 1.5 - t * 0.5;
            float2 center = float2(0.5, 0.5);
            float2 outUV = center + (uv - center) / outScale;
            float2 inUV = center + (uv - center) / inScale;
            float4 a = ajar_transition_sample(outgoingTexture, linearSampler, outUV);
            float4 b = ajar_transition_sample(incomingTexture, linearSampler, inUV);
            return ajar_transition_cross_dissolve(a, b, t);
        }

        """
}
