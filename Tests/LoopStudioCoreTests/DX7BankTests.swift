import Foundation
import Testing
@testable import LoopStudioCore

@Test func aVoiceRoundTripsThroughThePackedBytes() {
    var p = DX7.initVoice
    p[DX7.key(3, "r1")] = 57; p[DX7.key(3, "l4")] = 12; p[DX7.key(3, "lc")] = 2; p[DX7.key(3, "rc")] = 3
    p[DX7.key(3, "rs")] = 5; p[DX7.key(3, "det")] = 11; p[DX7.key(3, "ams")] = 2; p[DX7.key(3, "kvs")] = 6
    p[DX7.key(3, "ol")] = 88; p[DX7.key(3, "mode")] = 1; p[DX7.key(3, "coarse")] = 19; p[DX7.key(3, "fine")] = 42
    p["alg"] = 21; p["fb"] = 6; p["oks"] = 0; p["lfs"] = 70; p["lfd"] = 33; p["lpmd"] = 12; p["lamd"] = 9
    p["lfks"] = 0; p["lfw"] = 4; p["lpms"] = 5; p["transpose"] = 30; p["pr2"] = 77; p["pl3"] = 61
    let voice = DX7.Voice(name: "E.PIANO 1", params: p)
    let back = DX7.Voice(packed: voice.packed)
    #expect(back.name == "E.PIANO 1")
    for (k, v) in p where k != "volume" { #expect(back.params[k] == v, "\(k)") }
    #expect(voice.packed.count == 128)
}

@Test func aBankReadsAndWritesTheBulkDump() {
    let voices = (0..<32).map { i -> DX7.Voice in
        var p = DX7.initVoice
        p["alg"] = Double(i)
        p[DX7.key(1, "ol")] = Double(60 + i)
        return DX7.Voice(name: "VOICE \(i)", params: p)
    }
    let data = DX7.Bank(voices: voices).data
    #expect(data.count == DX7.Bank.size)
    #expect(data[0] == 0xF0 && data[1] == 0x43 && data[3] == 0x09 && data[4] == 0x20 && data[5] == 0x00 && data[4103] == 0xF7)
    // The checksum: the data bytes and it sum to a multiple of 128.
    let sum = data[6..<4103].reduce(0) { $0 + Int($1) }
    #expect(sum % 128 == 0)
    let bank = DX7.Bank(data: data)
    #expect(bank?.voices.count == 32)
    #expect(bank?.voices[5].name == "VOICE 5")
    #expect(bank?.voices[31].params["alg"] == 31)
    #expect(bank?.voices[7].params[DX7.key(1, "ol")] == 67)
    // The bare 4096 bytes read too; anything else does not.
    #expect(DX7.Bank(data: data[6..<4102])?.voices[5].name == "VOICE 5")
    #expect(DX7.Bank(data: Data(repeating: 0, count: 163)) == nil)
}

@Test func theSpecCoversEveryVoiceByte() {
    let keys = Set(DX7.spec.params.map(\.key))
    for op in 1...6 { for k in DX7.operatorKeys { #expect(keys.contains(DX7.key(op, k))) } }
    for k in DX7.globalKeys { #expect(keys.contains(k)) }
    #expect(DX7.spec.params.count == 6 * 22 + 20)
    #expect(DX7.spec.isInstrument)
    // A packed voice of zeros is a legal voice: the parser clamps nothing out of range.
    let zero = DX7.Voice(packed: [UInt8](repeating: 0, count: 128))
    for p in DX7.spec.params where p.key != "volume" && !p.key.hasSuffix(".on") {
        let v = zero.params[p.key]
        #expect(v != nil && v! >= p.min && v! <= p.max, "\(p.key)")
    }
    let full = DX7.Voice(packed: [UInt8](repeating: 0x7F, count: 128))
    for p in DX7.spec.params where p.key != "volume" {
        let v = full.params[p.key]
        #expect(v != nil && v! >= p.min && v! <= p.max, "\(p.key)")
    }
}
