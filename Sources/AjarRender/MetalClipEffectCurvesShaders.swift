// SPDX-License-Identifier: GPL-3.0-or-later

/// FR-COL-002 color-curves fragment shaders (appended after batch-1 effect helpers).
enum MetalClipEffectCurvesShaders {
    static let source = """

        // FR-COL-002: texel-center sample on a 256-entry 1D ramp (matches LUT lattice remap).
        static float ajar_curves_texel_coord(float logical, float size) {
            float safeSize = max(size, 2.0);
            return ((logical * (safeSize - 1.0)) + 0.5) / safeSize;
        }

        // Sample one packed channel from the RGBA curves ramp texture.
        // Layout: R=red, G=green, B=blue, A=master (CPU-baked Fritsch–Carlson).
        static float ajar_curves_sample_channel(
            texture1d<float> rampTexture,
            sampler samp,
            float logical,
            float size,
            int channel
        ) {
            float coord = ajar_curves_texel_coord(saturate(logical), size);
            float4 sample = rampTexture.sample(samp, coord);
            if (channel == 0) {
                return sample.r;
            }
            if (channel == 1) {
                return sample.g;
            }
            if (channel == 2) {
                return sample.b;
            }
            return sample.a;
        }

        // FR-COL-002 color curves: unpremultiply → master → R/G/B ramps → strength mix →
        // repremultiply. Linear working space; alpha preserved. Identity curves / strength 0
        // are skipped on the CPU encode path for bit-identical passthrough.
        fragment float4 ajar_curves_fragment(
            AjarVertexOut in [[stage_in]],
            texture2d<float> sourceTexture [[texture(0)]],
            texture1d<float> rampTexture [[texture(1)]],
            constant AjarCurvesUniforms &uniforms [[buffer(0)]]
        ) {
            constexpr sampler linearSampler(
                address::clamp_to_edge,
                filter::linear
            );
            float4 sourcePremult = sourceTexture.sample(linearSampler, in.uv);
            float alpha = saturate(sourcePremult.a);
            float strength = saturate(uniforms.strength);
            if (strength <= 0.0 || alpha <= 0.00001) {
                return sourcePremult;
            }
            float3 source = ajar_effect_unpremultiply(sourcePremult);
            float size = max(uniforms.rampSize, 2.0);
            // Master remaps each channel, then per-channel ramps refine.
            float rMaster = ajar_curves_sample_channel(
                rampTexture, linearSampler, source.r, size, 3
            );
            float gMaster = ajar_curves_sample_channel(
                rampTexture, linearSampler, source.g, size, 3
            );
            float bMaster = ajar_curves_sample_channel(
                rampTexture, linearSampler, source.b, size, 3
            );
            float3 curved = float3(
                ajar_curves_sample_channel(rampTexture, linearSampler, rMaster, size, 0),
                ajar_curves_sample_channel(rampTexture, linearSampler, gMaster, size, 1),
                ajar_curves_sample_channel(rampTexture, linearSampler, bMaster, size, 2)
            );
            float3 mixed = mix(source, curved, strength);
            return float4(max(mixed, float3(0.0)) * alpha, alpha);
        }
        """
}
