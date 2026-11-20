import SwiftUI

/// A clip's waveform over the view's width. `sourceAt` maps a fraction of the width to the file position
/// (0 to 1): the clip's warp mapping, see `AppModel.waveMap`. Below 0 or from 1 on, nothing is drawn.
struct WaveformView: View {
    let peaks: WavePeaks
    let color: Color
    let sourceAt: (Double) -> Double

    var body: some View {
        Canvas { ctx, size in
            guard size.width > 0 else { return }
            peaks.draw(in: ctx, from: 0, to: size.width, mid: size.height / 2, half: size.height * 0.46, color: color) {
                sourceAt(Double($0 / size.width))
            }
        }
    }
}
