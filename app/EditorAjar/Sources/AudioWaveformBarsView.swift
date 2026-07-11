// SPDX-License-Identifier: GPL-3.0-or-later

import AjarAudio
import SwiftUI

/// Peak bars from a cached `AudioWaveformSummary` (FR-MED-009 / FR-AUD-002).
///
/// Shared by the media browser (#235) and timeline audio clips so both surfaces reuse the same
/// rendering and cache-decoded summary type.
struct AudioWaveformBarsView: View {
    let summary: AudioWaveformSummary
    var maxBars: Int = 48
    var barColor: Color = Color.accentColor.opacity(0.85)

    var body: some View {
        GeometryReader { geometry in
            let bins = displayBins
            let count = max(bins.count, 1)
            let barWidth = max(1, geometry.size.width / CGFloat(count) * 0.7)
            let spacing = max(0.5, geometry.size.width / CGFloat(count) * 0.3)
            HStack(alignment: .center, spacing: spacing) {
                ForEach(Array(bins.enumerated()), id: \.offset) { _, amplitude in
                    RoundedRectangle(cornerRadius: 0.5)
                        .fill(barColor)
                        .frame(
                            width: barWidth,
                            height: max(2, CGFloat(amplitude) * geometry.size.height)
                        )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }

    /// Downsample to a readable bar count using peak absolute amplitude per bucket.
    private var displayBins: [Float] {
        let source = summary.channels.first?.bins ?? []
        guard !source.isEmpty else {
            return []
        }
        let target = min(maxBars, source.count)
        let group = max(1, source.count / target)
        var result: [Float] = []
        result.reserveCapacity(target)
        var index = 0
        while index < source.count {
            let end = min(index + group, source.count)
            let peak = source[index..<end].map { max(abs($0.minimum), abs($0.maximum)) }.max() ?? 0
            result.append(min(1, peak))
            index = end
        }
        return result
    }
}
