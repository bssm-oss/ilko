import Foundation

func encoderTests() async {
    let work = makeTempDir()

    await test("testEncodeProducesTemporalLayeredHEVC") {
        let src = work.appendingPathComponent("land.mov")
        try await makeTestVideo(url: src, size: CGSize(width: 640, height: 360), fps: 60, seconds: 2, barHeight: 20, withAudio: true)
        expect(try await audioTrackCount(src) == 1, "fixture has audio")
        let enc = AerialEncoder(cacheDir: work.appendingPathComponent("cache"))
        let out = try await enc.encode(source: src)
        expect(try await codecFourCC(out) == "hvc1", "hvc1, got \(try await codecFourCC(out))")
        let info = try await temporalInfoAndMonotonicPTS(out)
        expect(info.count > 0 && info.allTemporal, "every sample has HEVCTemporalLevelInfo")
        expect(try await audioTrackCount(out) == 0, "no audio")
        let fps = try await nominalFPS(out)
        expect(fps > 239 && fps < 241, "fps≈240, got \(fps)")
        let bars = try await blackBarRows(out)
        expect(bars.top <= 1 && bars.bottom <= 1, "bars cropped, got \(bars)")
    }

    await test("testCacheHit") {
        let src = work.appendingPathComponent("land.mov")
        let enc = AerialEncoder(cacheDir: work.appendingPathComponent("cache"))
        let a = try await enc.encode(source: src)
        let m1 = try FileManager.default.attributesOfItem(atPath: a.path)[.modificationDate] as? Date
        let b = try await enc.encode(source: src)
        let m2 = try FileManager.default.attributesOfItem(atPath: b.path)[.modificationDate] as? Date
        expect(a == b, "same cache URL")
        expect(m1 == m2, "not rewritten")
    }

    await test("testPortraitSource") {
        let src = work.appendingPathComponent("portrait.mov")
        try await makeTestVideo(url: src, size: CGSize(width: 360, height: 640), fps: 30, seconds: 1, barHeight: 0, withAudio: false)
        let out = try await AerialEncoder(cacheDir: work.appendingPathComponent("cache2")).encode(source: src)
        let size = try await naturalSize(out)
        expect(size == CGSize(width: 360, height: 640), "size kept, got \(size)")
        expect(try await temporalInfoAndMonotonicPTS(out).allTemporal, "temporal info")
    }

    await test("testNonIntegerFps") {
        let src = work.appendingPathComponent("pal.mov")
        try await makeTestVideo(url: src, size: CGSize(width: 320, height: 180), fps: 25, seconds: 1, barHeight: 0, withAudio: false)
        let out = try await AerialEncoder(cacheDir: work.appendingPathComponent("cache3")).encode(source: src)
        let fps = try await nominalFPS(out)
        expect(fps > 239 && fps < 241, "fps≈240, got \(fps)")
        expect(try await temporalInfoAndMonotonicPTS(out).monotonic, "PTS strictly increasing")
    }

    await test("testCacheKeepsAtMostFive") {
        let cache = work.appendingPathComponent("cache4")
        let enc = AerialEncoder(cacheDir: cache)
        for i in 0..<6 {
            let src = work.appendingPathComponent("tiny\(i).mov")
            try await makeTestVideo(url: src, size: CGSize(width: 160, height: 90), fps: 30, seconds: Double(i + 1) * 0.2, barHeight: 0, withAudio: false)
            _ = try await enc.encode(source: src)
        }
        let movs = try FileManager.default.contentsOfDirectory(atPath: cache.path).filter { $0.hasSuffix(".mov") }
        expect(movs.count == 5, "cache pruned to 5, got \(movs.count)")
    }
}
