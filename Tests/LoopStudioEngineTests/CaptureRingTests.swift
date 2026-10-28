import Testing
@testable import LoopStudioEngine

@Test func ringKeepsOrderAcrossTheWrap() {
    let ring = CaptureRing(channels: 2, capacity: 100)
    var out = [Float](repeating: 0, count: 700), outR = out
    var next: Float = 0, got = 0
    for _ in 0..<10 {
        let l = (0..<70).map { Float($0) + next }, r = l.map { -$0 }
        #expect(ring.write(l, r, frames: 70))
        next += 70
        got += out.withUnsafeMutableBufferPointer { o in outR.withUnsafeMutableBufferPointer { orr in
            ring.read(into: o.baseAddress! + got, orr.baseAddress! + got, max: 70)
        } }
        #expect(got == Int(next))
    }
    #expect(ring.dropped == 0)
    #expect(out == (0..<700).map(Float.init))
    #expect(outR == (0..<700).map { -Float($0) })
}

@Test func ringDropsWhatDoesNotFitAndCountsIt() {
    let ring = CaptureRing(channels: 1, capacity: 100)
    let block = [Float](repeating: 1, count: 60)
    #expect(ring.write(block, nil, frames: 60))
    #expect(!ring.write(block, nil, frames: 60))
    #expect(ring.dropped == 60)
    var out = [Float](repeating: 0, count: 100)
    #expect(out.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, nil, max: 100) } == 60)
}

@Test func ringFillsADropWithSilence() {
    let ring = CaptureRing(channels: 1, capacity: 100)
    let ones = [Float](repeating: 1, count: 60), twos = [Float](repeating: 2, count: 30)
    #expect(ring.write(ones, nil, frames: 60))
    #expect(!ring.write(ones, nil, frames: 60), "does not fit: dropped")
    var out: [Float] = []
    var chunk = [Float](repeating: 9, count: 100)
    func drain() {
        while true {
            let n = chunk.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, nil, max: 100) }
            if n == 0 { break }
            out += chunk[0..<n]
        }
    }
    drain()
    #expect(ring.write(twos, nil, frames: 30))
    drain()
    #expect(out.count == 150, "the dropped frames come back as silence")
    #expect(out[0..<60].allSatisfy { $0 == 1 } && out[60..<120].allSatisfy { $0 == 0 } && out[120..<150].allSatisfy { $0 == 2 })
}
