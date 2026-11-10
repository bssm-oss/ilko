import AVFoundation
import CoreImage

/// 단색 프레임 + 위아래 검은 띠 테스트 영상 생성 (H.264, 선택적 무음 오디오)
func makeTestVideo(url: URL, size: CGSize, fps: Int32, seconds: Double, barHeight: Int, withAudio: Bool) async throws {
    try? FileManager.default.removeItem(at: url)
    let w = Int(size.width), h = Int(size.height)
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let vin = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h,
    ])
    let ad = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vin, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
    ])
    writer.add(vin)
    var ain: AVAssetWriterInput?
    if withAudio {
        let a = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 1,
        ])
        writer.add(a); ain = a
    }
    writer.startWriting(); writer.startSession(atSourceTime: .zero)

    let frames = Int(Double(fps) * seconds)
    for i in 0..<frames {
        while !vin.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, ad.pixelBufferPool!, &pb)
        CVPixelBufferLockBaseAddress(pb!, [])
        let base = CVPixelBufferGetBaseAddress(pb!)!.assumingMemoryBound(to: UInt8.self)
        let bpr = CVPixelBufferGetBytesPerRow(pb!)
        for y in 0..<h {
            let dark = y < barHeight || y >= h - barHeight
            for x in 0..<w {
                let p = base + y * bpr + x * 4
                p[0] = dark ? 0 : 60; p[1] = dark ? 0 : 160; p[2] = dark ? 0 : 220; p[3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(pb!, [])
        ad.append(pb!, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: fps))
    }
    vin.markAsFinished()

    if let a = ain {
        // 무음 PCM 을 AAC 로
        var fmt = AudioStreamBasicDescription(mSampleRate: 44100, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        var fd: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &fmt, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                       magicCookie: nil, extensions: nil, formatDescriptionOut: &fd)
        let n = Int(44100 * seconds)
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: n * 2, blockAllocator: nil,
            customBlockSource: nil, offsetToData: 0, dataLength: n * 2, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        CMBlockBufferFillDataBytes(with: 0, blockBuffer: block!, offsetIntoDestination: 0, dataLength: n * 2)
        var sb: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block!, formatDescription: fd!,
            sampleCount: n, presentationTimeStamp: .zero, packetDescriptions: nil, sampleBufferOut: &sb)
        while !a.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
        a.append(sb!); a.markAsFinished()
    }
    await writer.finishWriting()
    if writer.status != .completed { throw writer.error ?? LockScreenError.io("test video") }
}

// MARK: - 결과 검증 헬퍼

func videoTrack(_ url: URL) async throws -> AVAssetTrack {
    try await AVURLAsset(url: url).loadTracks(withMediaType: .video)[0]
}

func codecFourCC(_ url: URL) async throws -> String {
    let fd = try await videoTrack(url).load(.formatDescriptions)[0]
    let c = CMFormatDescriptionGetMediaSubType(fd).bigEndian
    return String(bytes: withUnsafeBytes(of: c, Array.init), encoding: .ascii) ?? "?"
}

func audioTrackCount(_ url: URL) async throws -> Int {
    try await AVURLAsset(url: url).loadTracks(withMediaType: .audio).count
}

func nominalFPS(_ url: URL) async throws -> Float {
    try await videoTrack(url).load(.nominalFrameRate)
}

func naturalSize(_ url: URL) async throws -> CGSize {
    try await videoTrack(url).load(.naturalSize)
}

/// 모든 샘플이 HEVCTemporalLevelInfo 를 갖는지, PTS 가 (표시순) 단조 증가하는지
func temporalInfoAndMonotonicPTS(_ url: URL) async throws -> (allTemporal: Bool, monotonic: Bool, count: Int) {
    let asset = AVURLAsset(url: url)
    let t = try await asset.loadTracks(withMediaType: .video)[0]
    let r = try AVAssetReader(asset: asset)
    let o = AVAssetReaderTrackOutput(track: t, outputSettings: nil)
    r.add(o); r.startReading()
    var all = true, n = 0
    var pts: [Double] = []
    while let sb = o.copyNextSampleBuffer() {
        guard CMSampleBufferGetNumSamples(sb) > 0 else { continue }
        n += 1
        pts.append(CMSampleBufferGetPresentationTimeStamp(sb).seconds)
        let att = (CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]])?.first
        if att?["HEVCTemporalLevelInfo" as CFString] == nil { all = false }
    }
    let sorted = pts.sorted()
    let mono = zip(sorted, sorted.dropFirst()).allSatisfy { $0 < $1 }
    return (all, mono, n)
}

/// 중간 프레임의 위/아래 검은 행 수
func blackBarRows(_ url: URL) async throws -> (top: Int, bottom: Int) {
    let asset = AVURLAsset(url: url)
    let dur = try await asset.load(.duration)
    let g = AVAssetImageGenerator(asset: asset)
    g.requestedTimeToleranceBefore = .zero; g.requestedTimeToleranceAfter = .zero
    let (img, _) = try await g.image(at: CMTimeMultiplyByFloat64(dur, multiplier: 0.5))
    let w = img.width, h = img.height
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
    func dark(_ y: Int) -> Bool {
        var m = 0
        for x in stride(from: 0, to: w, by: 4) { let i = (y * w + x) * 4; m = max(m, Int(p[i]) + Int(p[i + 1]) + Int(p[i + 2])) }
        return m < 40
    }
    var top = 0; while top < h / 2 && dark(top) { top += 1 }
    var bot = 0; while bot < h / 2 && dark(h - 1 - bot) { bot += 1 }
    return (top, bot)
}
