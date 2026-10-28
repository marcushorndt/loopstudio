import SwiftUI

/// Draws peak bars. `fraction` is how much of the sample the width covers; a looped clip repeats.
struct WaveformView: View {
    let peaks: [Float]
    let color: Color
    var fraction: Double = 1
    var loop = false

    var body: some View {
        Canvas { ctx, size in
            guard !peaks.isEmpty, size.width > 0 else { return }
            let mid = size.height / 2
            var path = Path()
            var x: CGFloat = 0
            while x < size.width {
                var src = Double(x / size.width) * fraction
                if loop { src = src.truncatingRemainder(dividingBy: 1) } else if src >= 1 { break }
                let amp = CGFloat(peaks[min(peaks.count - 1, Int(src * Double(peaks.count)))]) * (size.height * 0.46)
                path.addRect(CGRect(x: x, y: mid - max(0.5, amp), width: 1.2, height: max(1, amp * 2)))
                x += 1.5
            }
            ctx.fill(path, with: .color(color))
        }
    }
}
