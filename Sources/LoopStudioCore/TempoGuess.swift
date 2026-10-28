import Foundation

public enum TempoGuess {
    /// A tempo named in a file name: "loop_120bpm.wav", "Drums 92 BPM.aif", "pad-85-Am.wav".
    /// Returns nil when no number between 50 and 220 stands out. Never guesses from the audio.
    public static func fromFileName(_ name: String) -> Double? {
        let base = (name as NSString).deletingPathExtension
        if let value = firstMatch(#"(\d{2,3}(?:[.,]\d+)?)\s*[-_ ]?bpm"#, in: base) { return plausible(value) }
        if let value = firstMatch(#"bpm\s*[-_ ]?(\d{2,3}(?:[.,]\d+)?)"#, in: base) { return plausible(value) }
        // A bare number between separators, like "pad_85_Am".
        if let value = firstMatch(#"(?:^|[-_ ])(\d{2,3})(?=[-_ ]|$)"#, in: base) { return plausible(value) }
        return nil
    }

    private static func plausible(_ text: String) -> Double? {
        guard let v = Double(text.replacingOccurrences(of: ",", with: ".")), (50...220).contains(v) else { return nil }
        return v
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }
}
