// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore

enum BenchmarkEffectNodeBatch2Definitions {
    static func definition(for metric: BenchmarkMetric) throws -> ClipEffectDefinition {
        switch metric {
        case .effectNodeVignette1080p:
            return .vignette(
                ClipVignetteParameters(
                    amount: try RationalValue(numerator: 3, denominator: 4),
                    radius: try RationalValue(numerator: 1, denominator: 2),
                    softness: try RationalValue(numerator: 1, denominator: 4)
                )
            )
        case .effectNodeMirror1080p:
            return .mirror(ClipMirrorParameters(axis: .quad))
        case .effectNodeMosaic1080p:
            return .mosaic(ClipMosaicParameters(cellSize: RationalValue(12)))
        case .effectNodeColorAdjust1080p:
            return .colorAdjust(
                ClipColorAdjustParameters(
                    brightness: try RationalValue(numerator: 1, denominator: 10),
                    contrast: try RationalValue(numerator: 6, denominator: 5),
                    saturation: try RationalValue(numerator: 4, denominator: 5),
                    tint: try RationalValue(numerator: 1, denominator: 5)
                )
            )
        case .effectNodePosterize1080p:
            return .posterize(ClipPosterizeParameters(levels: RationalValue(4)))
        case .effectNodeInvert1080p:
            return .invert(ClipInvertParameters())
        default:
            throw AjarCLIError.benchmarkFailed(
                "metric \(metric.rawValue) is not an FR-FX-002 batch-2 effect metric"
            )
        }
    }
}
