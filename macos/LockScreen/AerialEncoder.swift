import AVFoundation
import CoreImage
import CryptoKit

/// 원본 영상을 macOS Aerial 플레이어가 재생할 수 있는 형식으로 변환하고 캐시한다.
///
/// Aerial 플레이어 요구사항(2026-11 macOS 27 에서 검증):
/// - HEVC + 시간 계층(모든 샘플에 `HEVCTemporalLevelInfo`). 없으면 잠금 해제 시
///   `VideoSampleReadingErrors.noTemporalInfo` 로 데스크탑이 회색이 된다.
/// - 240fps, 오디오 없음. 플레이어는 aspect-fill 로 그리므로 영상에 박힌 검은 띠는 잘라낸다.
actor AerialEncoder {
    nonisolated static let defaultCacheDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/ilko/lockscreen-cache")
    nonisolated static let outputFPS: Int32 = 240
    nonisolated static let maxCachedFiles = 5
    /// 인코딩 방식이 바뀌면 올려서 이전 캐시를 무효화한다.
    nonisolated static let formatVersion = "v2"

    private let cacheDir: URL
    /// 같은 원본에 대한 진행 중 변환 + 기다리는 호출자들. 대기자가 모두 취소되면 변환도 취소한다.
    private var inflight: [String: (task: Task<URL, Error>, waiters: Set<UUID>)] = [:]

    init(cacheDir: URL = AerialEncoder.defaultCacheDir) {
        self.cacheDir = cacheDir
    }

    /// 변환된 캐시 파일 URL 을 반환한다(이미 있으면 즉시).
    func encode(source: URL) async throws -> URL {
        let key = try Self.cacheKey(for: source)
        let dest = cacheDir.appendingPathComponent("\(key).mov")
        if FileManager.default.fileExists(atPath: dest.path) { return dest }
        let task: Task<URL, Error>
        if let running = inflight[key] {
            task = running.task
        } else {
            let dir = cacheDir
            task = Task.detached(priority: .utility) {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try await Self.transcode(source: source, to: dest)
                return dest
            }
            inflight[key] = (task, [])
        }
        let waiter = UUID()
        inflight[key]?.waiters.insert(waiter)
        defer { leave(key, waiter, cancelIfLast: false) }
        // 호출자 취소는 detached 변환에 전파되지 않으므로 직접 전달한다
        let result = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            Task { await self.leave(key, waiter, cancelIfLast: true) }
        }
        pruneCache(keeping: result)
        return result
    }

    private func leave(_ key: String, _ waiter: UUID, cancelIfLast: Bool) {
        guard var entry = inflight[key], entry.waiters.contains(waiter) else { return }
        entry.waiters.remove(waiter)
        if entry.waiters.isEmpty {
            if cancelIfLast { entry.task.cancel() }
            inflight[key] = nil
        } else {
            inflight[key] = entry
        }
    }

    /// 원본 내용 기반 캐시 키 (SHA-256 앞 16자 + 포맷 버전)
    nonisolated static func cacheKey(for source: URL) throws -> String {
        guard let fh = try? FileHandle(forReadingFrom: source) else {
            throw LockScreenError.io("cannot read \(source.path)")
        }
        defer { try? fh.close() }
        var hasher = SHA256()
        hasher.update(data: Data(formatVersion.utf8))
        while let chunk = try fh.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined().prefix(16).description
    }

    private func pruneCache(keeping: URL) {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: cacheDir, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return }
        var files: [(url: URL, date: Date)] = []
        for u in urls where u.pathExtension == "mov" && !u.lastPathComponent.contains(".tmp")
            && u.lastPathComponent != keeping.lastPathComponent {
            let d = (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            files.append((u, d))
        }
        files.sort { $0.date > $1.date }
        for f in files.dropFirst(Self.maxCachedFiles - 1) { try? FileManager.default.removeItem(at: f.url) }
    }

    // MARK: - 변환

    nonisolated private static func transcode(source: URL, to dest: URL) async throws {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw LockScreenError.encodeFailed("no video track")
        }
        let (natural, transform, fps) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate)

        // 회전 반영한 표시 크기
        let oriented = CGRect(origin: .zero, size: natural).applying(transform)
        let orientedSize = CGSize(width: abs(oriented.width), height: abs(oriented.height))
        // preferredTransform 은 좌상단 원점 기준인데 CIImage 는 좌하단 원점이다.
        // CI→좌상단(입력 높이로 y 반전) → 회전/정규화 → 좌상단→CI(출력 높이로 y 반전)
        let flipIn = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: natural.height)
        let flipOut = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: orientedSize.height)
        let normalize = flipIn
            .concatenating(transform)
            .concatenating(CGAffineTransform(translationX: -oriented.minX, y: -oriented.minY))
            .concatenating(flipOut)

        let content = try await contentRect(asset: asset, size: orientedSize)
        let outSize = outputSize(for: orientedSize)

        let tmp = dest.deletingPathExtension().appendingPathExtension("tmp.mov")
        try? FileManager.default.removeItem(at: tmp)
        do {
            try await write(asset: asset, track: track, fps: fps, normalize: normalize,
                            content: content, outSize: outSize, to: tmp)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tmp, to: dest)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw (error as? LockScreenError) ?? LockScreenError.encodeFailed("\(error)")
        }
    }

    /// 4K 이하로 축소, 짝수 크기
    nonisolated static func outputSize(for size: CGSize) -> CGSize {
        let longMax: CGFloat = 3840, shortMax: CGFloat = 2160
        let long = max(size.width, size.height), short = min(size.width, size.height)
        let scale = min(1, longMax / long, shortMax / short)
        func even(_ v: CGFloat) -> CGFloat { max(2, (v * scale / 2).rounded(.down) * 2) }
        return CGSize(width: even(size.width), height: even(size.height))
    }

    /// 중간 프레임에서 위/아래/좌/우 검은 띠를 재고, 띠를 뺀 영역(좌하단 원점, CI 좌표)을 반환.
    nonisolated private static func contentRect(asset: AVURLAsset, size: CGSize) async throws -> CGRect {
        let full = CGRect(origin: .zero, size: size)
        let dur = try await asset.load(.duration)
        let g = AVAssetImageGenerator(asset: asset)
        g.appliesPreferredTrackTransform = true
        guard let (img, _) = try? await g.image(at: CMTimeMultiplyByFloat64(dur, multiplier: 0.5)) else { return full }
        let w = img.width, h = img.height
        guard w > 0, h > 0,
            let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return full }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
        // CGContext 메모리는 위쪽 행부터
        func px(_ x: Int, _ y: Int) -> Int { let i = (y * w + x) * 4; return Int(p[i]) + Int(p[i + 1]) + Int(p[i + 2]) }
        func rowDark(_ y: Int) -> Bool { stride(from: 0, to: w, by: 4).allSatisfy { px($0, y) < 40 } }
        func colDark(_ x: Int) -> Bool { stride(from: 0, to: h, by: 4).allSatisfy { px(x, $0) < 40 } }
        // 한 변당 최대 25% 까지만 (전체가 어두운 장면을 통째로 잘라내지 않도록), 2px 미만은 노이즈로 무시
        func measure(_ limit: Int, _ dark: (Int) -> Bool) -> Int {
            var n = 0; while n < limit && dark(n) { n += 1 }
            return n >= limit || n < 2 ? 0 : n
        }
        let top = measure(h / 4) { rowDark($0) }
        let bottom = measure(h / 4) { rowDark(h - 1 - $0) }
        let left = measure(w / 4) { colDark($0) }
        let right = measure(w / 4) { colDark(w - 1 - $0) }
        let sx = size.width / CGFloat(w), sy = size.height / CGFloat(h)
        return CGRect(x: CGFloat(left) * sx, y: CGFloat(bottom) * sy,
                      width: size.width - CGFloat(left + right) * sx,
                      height: size.height - CGFloat(top + bottom) * sy)
    }

    nonisolated private static func write(asset: AVURLAsset, track: AVAssetTrack, fps: Float,
                                          normalize: CGAffineTransform, content: CGRect, outSize: CGSize,
                                          to url: URL) async throws {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: outSize.width,
            AVVideoHeightKey: outSize.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 40_000_000,
                AVVideoExpectedSourceFrameRateKey: outputFPS,
                // VideoToolbox: 기본 계층 프레임레이트 → HEVC 시간 계층 생성 (핵심)
                "BaseLayerFrameRate": 30,
            ] as [String: Any],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: outSize.width,
            kCVPixelBufferHeightKey as String: outSize.height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ])
        writer.add(input)
        guard reader.startReading(), writer.startWriting() else {
            throw LockScreenError.encodeFailed("start: \(reader.error ?? writer.error as Any)")
        }
        writer.startSession(atSourceTime: .zero)

        // 띠 영역 crop → 출력 크기를 채우도록 확대 → 중앙 crop
        let scale = max(outSize.width / content.width, outSize.height / content.height)
        let place = CGAffineTransform(translationX: -content.minX, y: -content.minY)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: (outSize.width - content.width * scale) / 2,
                                             y: (outSize.height - content.height * scale) / 2))
        let outRect = CGRect(origin: .zero, size: outSize)
        let ci = CIContext(options: [.cacheIntermediates: false])

        func render(_ src: CVPixelBuffer) throws -> CVPixelBuffer {
            var out: CVPixelBuffer?
            guard let pool = adaptor.pixelBufferPool,
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess, let out
            else { throw LockScreenError.encodeFailed("pixel buffer pool") }
            let img = CIImage(cvPixelBuffer: src).transformed(by: normalize).cropped(to: content)
                .transformed(by: place).cropped(to: outRect)
            ci.render(img, to: out)
            return out
        }

        // 원본 프레임 i 를 [pts_i, pts_{i+1}) 구간의 모든 1/240 틱에 배치 → 어떤 fps 든 실제 속도 유지
        let tick = Double(outputFPS)
        let frameDur = 1.0 / Double(fps > 0 ? fps : 30)
        var nextTick: Int64 = 0
        var pending: (buffer: CVPixelBuffer, pts: Double)?

        func emit(_ buf: CVPixelBuffer, until endTime: Double) async throws {
            let lastTick = Int64((endTime * tick).rounded(.up))
            while nextTick < lastTick {
                while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
                if !adaptor.append(buf, withPresentationTime: CMTime(value: nextTick, timescale: outputFPS)) {
                    throw LockScreenError.encodeFailed("append: \(writer.error as Any)")
                }
                nextTick += 1
            }
        }

        while let sb = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let src = CMSampleBufferGetImageBuffer(sb) else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sb).seconds
            if let p = pending { try await emit(p.buffer, until: pts) }
            pending = (try render(src), pts)
        }
        if let p = pending { try await emit(p.buffer, until: p.pts + frameDur) }

        if reader.status == .failed { throw LockScreenError.encodeFailed("read: \(reader.error as Any)") }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed, nextTick > 0 else {
            throw LockScreenError.encodeFailed("write: \(writer.error as Any)")
        }
    }
}
