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

func encoderReviewTests() async {
    let work = makeTempDir()

    // I1: 회전 메타데이터(아이폰 세로)가 있는 원본의 방향이 결과에서 유지되어야 한다
    await test("testRotatedSourceKeepsOrientation") {
        let src = work.appendingPathComponent("rotated.mov")
        // 버퍼 640x360, 90° 회전 → 표시 360x640
        try await makeTestVideo(url: src, size: CGSize(width: 640, height: 360), fps: 30, seconds: 1, barHeight: 0,
                                withAudio: false, transform: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 360, ty: 0),
                                splitColors: true)
        let points = [(0.5, 0.1), (0.5, 0.9)]
        let expected = try await isRedAt(src, points)
        expect(expected[0] != expected[1], "oracle: top/bottom differ \(expected)")
        let out = try await AerialEncoder(cacheDir: work.appendingPathComponent("rc")).encode(source: src)
        expect(try await naturalSize(out) == CGSize(width: 360, height: 640), "display size")
        let got = try await isRedAt(out, points)
        expect(got == expected, "orientation kept: expected \(expected) got \(got)")
    }

    // I2: 호출자가 취소되면 (다른 대기자가 없을 때) 변환도 멈춰야 한다
    await test("testCancelStopsEncode") {
        let src = work.appendingPathComponent("long.mov")
        try await makeTestVideo(url: src, size: CGSize(width: 1280, height: 720), fps: 30, seconds: 6, barHeight: 0, withAudio: false)
        let cache = work.appendingPathComponent("cc")
        let enc = AerialEncoder(cacheDir: cache)
        let t = Task { try await enc.encode(source: src) }
        try await Task.sleep(nanoseconds: 300_000_000)
        t.cancel()
        var threw = false
        do { _ = try await t.value } catch { threw = true }
        expect(threw, "cancelled encode throws")
        try await Task.sleep(nanoseconds: 500_000_000)
        let movs = (try? FileManager.default.contentsOfDirectory(atPath: cache.path))?.filter { $0.hasSuffix(".mov") } ?? []
        expect(movs.isEmpty, "no cache file after cancel, got \(movs)")
    }

    // I2: 같은 원본을 기다리는 다른 호출자가 있으면 한쪽 취소로 변환이 멈추면 안 된다
    await test("testJoinedWaiterSurvivesOtherCancel") {
        let src = work.appendingPathComponent("long.mov")
        let enc = AerialEncoder(cacheDir: work.appendingPathComponent("cj"))
        let t1 = Task { try await enc.encode(source: src) }
        let t2 = Task { try await enc.encode(source: src) }
        try await Task.sleep(nanoseconds: 300_000_000)
        t1.cancel()
        let url = try await t2.value
        expect(FileManager.default.fileExists(atPath: url.path), "survivor gets file")
    }
}
