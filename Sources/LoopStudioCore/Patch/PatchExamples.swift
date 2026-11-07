import Foundation

/// Patches that ship with the app: the starter of a new Patch device, and the examples in the editor's menu.
/// The tests compile and render every one of them.
public enum PatchExamples {
    public static let starter = """
    patch "My Patch"
    // Knobs: param name min..max = default [log] ["unit"]
    param drive 0..1 = 0.2
    param tone 200..12000 = 4000 log "Hz"
    param mix 0..1 = 1

    in x
    out y

    // One line per value, once per sample. x is the input, y the output.
    warm = tanh(x * (1 + 6 * drive))
    soft = lp(warm, tone, 0.3)
    y = mix(x, soft, mix)
    """

    public static let stutterFilter = """
    patch "Stutter Filter"
    param cutoff 20..20000 = 1200 log "Hz"
    param res 0..1 = 0.3
    param rate note = 1/16
    param depth 0..1 = 0.8
    param feedback 0..0.95 = 0.4

    in x
    out y
    delay line = 2 s

    // A square LFO on the song clock gates the filter open: a stutter that stays on the grid.
    gate = lfo(rate, square)
    env  = slew(gate, 2 ms, 40 ms)
    cut  = cutoff * (1 + 2 * depth * env)
    wet  = lp(x, cut, res)
    line.write(wet + line.read(rate) * feedback)
    y    = mix(x, line.read(rate), 0.5 * depth) + wet * 0.5
    """

    public static let tremolo = """
    patch "Tremolo"
    param rate note = 1/8
    param depth 0..1 = 0.6
    param shape 0..1 = 0

    in x
    out y
    meter level

    // The LFO follows the tempo; shape blends a sine into a square.
    soft  = lfo(rate, sine)
    hard  = lfo(rate, square)
    wave  = mix(soft, hard, shape)
    level = 1 - depth * (1 - wave)
    y     = x * level
    """

    public static let comb = """
    patch "Comb"
    param time 0.5..50 = 8 log "ms"
    param feedback 0..0.98 = 0.7
    param damp 500..20000 = 6000 log "Hz"
    param mix 0..1 = 0.5

    in x
    out y
    delay line = 100 ms

    // A short delay fed back through a low-pass: a comb filter with a tone.
    back = lp(line.read(time), damp)
    line.write(x + back * feedback)
    y = mix(x, back, mix)
    """

    public static let all: [(name: String, source: String)] = [
        ("Starter", starter), ("Stutter Filter", stutterFilter), ("Tremolo", tremolo), ("Comb", comb),
    ]

    /// The language on one page, for the editor's help and the MCP resource `loopstudio://help/patch`.
    public static let reference = """
    THE PATCH LANGUAGE (stage 1)

    A patch is text. One statement per line. Everything runs once per sample on stereo values; a plain
    number is the same on both channels. Lines in any order; a name must be set above the line that uses it.

    Declarations
      patch "Name"                          the device's name
      param key min..max = default          a knob; options after it: log, "unit" ("Hz", "ms", "dB", "%")
                                            a "ms" knob is seconds inside the program
      param key note = 1/16                 a note value knob (1/1 … 1/64, dotted with ., triplet with T);
                                            it follows the tempo
      in x                                  the input (default x)
      out y                                 the output; y must be set
      delay name = 2 s                      a delay line (1 ms … 60 s), stereo
      meter name                            show a value on the card (up to 4)

    Statements
      name = expression
      name.write(expression)                write into a delay at its record head

    Expressions
      + - * / ^   > < >= <= == (0 or 1)   ( )   -x
      numbers with units: 10 ms, 2 s, 440 Hz, 2 kHz, -6 dB; note values: 1/16, 1/8., 1/4T
      beat (quarter notes from the start), bar (0..1 inside the bar), tempo (BPM), sr, pi
      osc(hz, shape, offset)   -1..1 oscillator; shape: sine saw square tri; offset 0..1 moves the zero point
      lfo(rate, shape, offset) 0..1; a note value as the rate locks it to the song grid; lfo(1/4, sine, 0.25) peaks on the beat
      phase(1/16, offset)      0..1 inside the note value; the offset moves the zero point away from the beat
      lp(x, hz, q) hp(…) bp(…)   state-variable filter, q 0..1
      slew(x, up, down)     limits how fast x moves (times)
      follow(x, attack, release)   envelope of |x| (times)
      prev(name)            the value of name at the last frame: feedback without a delay line
      sah(x, trigger)       sample x when the trigger rises above 0.5
      noise()               white noise -1..1
      name.read(time)       a delay read that many seconds back (a note value works too)
      tanh abs sqrt sin cos exp log floor   clip(x, lo, hi)   mix(a, b, t)   min max pow   gain(dB)

    Units convert where a function asks for one: a note value becomes seconds or hertz from the tempo;
    seconds and hertz convert into each other. A time knob in "ms" arrives as seconds.

    Example
      patch "Tremolo"
      param rate note = 1/8
      param depth 0..1 = 0.6
      in x
      out y
      y = x * (1 - depth * (1 - lfo(rate, sine)))
    """
}

public extension PatchExamples {
    /// The text of a new Script module in a graph: one knob, the input passed through it.
    static let scriptStarter = """
    patch "Script"

    param amount 0..1 = 0.5

    in x
    out y

    y = x * amount
    """
}
