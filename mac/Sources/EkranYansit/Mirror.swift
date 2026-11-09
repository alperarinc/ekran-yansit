import AppKit
import CoreMedia
import Foundation
import Network
import ScreenCaptureKit
import VideoToolbox
import VirtualDisplayShim

// MARK: - Saf yardımcılar (selftest ile kontrol edilir)

/// VideoToolbox'ın AVCC çıktısını (4 bayt uzunluk + NAL) Annex-B'ye (00 00 00 01 + NAL) çevirir.
func avccToAnnexB(_ d: Data) -> Data {
    var out = Data(capacity: d.count)
    var i = d.startIndex
    while i + 4 <= d.endIndex {
        let n = d[i..<i + 4].reduce(0) { $0 << 8 | Int($1) }
        i += 4
        guard i + n <= d.endIndex else { break }
        out += [0, 0, 0, 1]
        out += d[i..<i + n]
        i += n
    }
    return out
}

/// Float örnekleri s16le interleaved stereo'ya çevirir. sample(kanal, kare) -> Float
func interleaveS16(frames: Int, channels: Int, sample: (Int, Int) -> Float) -> Data {
    var out = Data(count: frames * 4)
    out.withUnsafeMutableBytes { raw in
        let p = raw.bindMemory(to: Int16.self)
        for f in 0..<frames {
            for c in 0..<2 {
                let x = sample(min(c, channels - 1), f) // mono ise iki kulağa da aynı
                p[f * 2 + c] = Int16(max(-1, min(1, x)) * 32767).littleEndian
            }
        }
    }
    return out
}

func packet(_ type: UInt8, _ pts: UInt64, _ payload: Data) -> Data {
    var d = Data([type])
    withUnsafeBytes(of: pts.bigEndian) { d += $0 }
    withUnsafeBytes(of: UInt32(payload.count).bigEndian) { d += $0 }
    return d + payload
}

/// Yükseklik ve en-boy oranından H.264'e uygun (çift) genişlik
func evenWidth(height: Int, aspect: Double) -> Int { Int((Double(height) * aspect).rounded()) & ~1 }

func selfTest() {
    let avcc = Data([0, 0, 0, 2, 0xAA, 0xBB, 0, 0, 0, 1, 0xCC])
    precondition(avccToAnnexB(avcc) == Data([0, 0, 0, 1, 0xAA, 0xBB, 0, 0, 0, 1, 0xCC]))
    precondition(avccToAnnexB(Data([0, 0, 0, 9, 1])) == Data()) // kesik veri taşmaz
    let pcm = interleaveS16(frames: 1, channels: 1) { _, _ in 2.0 } // mono + kırpma
    precondition(pcm == Data([0xFF, 0x7F, 0xFF, 0x7F]))
    precondition(packet(2, 1, Data([9])) == Data([2, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 1, 9]))
    precondition(evenWidth(height: 1080, aspect: 16.0 / 9) == 1920)
    precondition(evenWidth(height: 1080, aspect: 3024.0 / 1964) == 1662)
    precondition(shellQuote("a b'c") == "'a b'\\''c'")
    let f = CGRect(x: 100, y: 0, width: 200, height: 100)
    precondition(cursorPosition(CGPoint(x: 150, y: 25), in: f)! == (0.25, 0.25))
    precondition(cursorPosition(CGPoint(x: 50, y: 25), in: f) == nil) // başka ekranda
    print("selftest ok")
}

/// İmlecin yakalanan ekrandaki yeri (0…1), ekran dışındaysa nil. Koordinatlar Quartz global (sol üst köken).
func cursorPosition(_ p: CGPoint, in f: CGRect) -> (Float, Float)? {
    f.contains(p) ? (Float((p.x - f.minX) / f.width), Float((p.y - f.minY) / f.height)) : nil
}

// MARK: - Sanal ekran (Genişlet modu)

func makeVirtualDisplay(width: Int, height: Int, fps: Int) -> CGVirtualDisplay? {
    let d = CGVirtualDisplayDescriptor()
    d.queue = .main
    d.name = "Ekran Yansıt TV"
    d.maxPixelsWide = UInt32(width)
    d.maxPixelsHigh = UInt32(height)
    d.sizeInMillimeters = CGSize(width: 1210, height: 680) // ~55" TV; macOS ölçeklemesi buna bakar
    d.serialNum = 0x4559
    d.productID = 0xE7A1
    d.vendorID = 0xE7A1
    d.terminationHandler = { _, _ in }
    let v = CGVirtualDisplay(descriptor: d)
    let s = CGVirtualDisplaySettings()
    s.hiDPI = 0
    s.modes = [CGVirtualDisplayMode(width: UInt32(width), height: UInt32(height), refreshRate: Double(fps))]
    guard let v, v.apply(s) else { return nil }
    return v
}

// MARK: - Yakalama + kodlama + gönderme

struct MirrorOptions {
    var extend = false   // true: TV ikinci ekran, false: ana ekranı yansıt
    var height = 1080
    var fps = 30
    var bitrateMbps = 8
}

final class Mirror: NSObject, SCStreamOutput, SCStreamDelegate {
    private let q = DispatchQueue(label: "mirror")
    private var stream: SCStream?
    private var conn: NWConnection?
    private var encoder: VTCompressionSession?
    private var virtualDisplay: CGVirtualDisplay?
    private var sentConfig = false
    // İmleç görüntüye gömülmez; konumu ayrı ve sık gönderilir, TV tampona sokmadan anında çizer
    private var cursorTimer: DispatchSourceTimer?
    private var displayFrame = CGRect.zero
    private var lastCursorPos: (Float, Float)?? = .none
    private var lastCursorTIFF: Data?
    private var cursorTick = 0
    var onStop: ((String?) -> Void)?

    func start(host: String, options o: MirrorOptions) async throws {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let c = NWConnection(host: .init(host), port: 7070, using: NWParameters(tls: nil, tcp: tcp))
        c.stateUpdateHandler = { [weak self] st in
            switch st {
            case .failed(let e), .waiting(let e): self?.stop("TV'ye bağlanılamadı (TV'de alıcı açık mı?): \(e)")
            default: break
            }
        }
        c.start(queue: q)
        conn = c

        let display: SCDisplay, w: Int, h = o.height
        if o.extend {
            w = evenWidth(height: h, aspect: 16.0 / 9)
            let vd = await MainActor.run { makeVirtualDisplay(width: w, height: h, fps: o.fps) }
            guard let vd else { throw err("Sanal ekran oluşturulamadı (macOS bu özelliği desteklemiyor olabilir).") }
            virtualDisplay = vd
            display = try await waitForDisplay(id: vd.displayID)
        } else {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let main = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first
            else { throw err("Ekran bulunamadı") }
            display = main
            w = evenWidth(height: h, aspect: Double(main.width) / Double(main.height))
        }

        let cfg = SCStreamConfiguration()
        cfg.width = w
        cfg.height = h
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(o.fps))
        cfg.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        cfg.queueDepth = 5
        cfg.capturesAudio = true
        cfg.sampleRate = 48000
        cfg.channelCount = 2
        cfg.excludesCurrentProcessAudio = true
        cfg.showsCursor = false

        var vt: VTCompressionSession?
        let st = VTCompressionSessionCreate(allocator: nil, width: Int32(w), height: Int32(h), codecType: kCMVideoCodecType_H264,
                                            encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
                                            outputCallback: nil, refcon: nil, compressionSessionOut: &vt)
        guard st == noErr, let vt else { throw err("H.264 kodlayıcı açılamadı (\(st))") }
        let props: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_H264_High_AutoLevel,
            kVTCompressionPropertyKey_AllowFrameReordering: false,
            kVTCompressionPropertyKey_MaxKeyFrameInterval: o.fps * 2,
            kVTCompressionPropertyKey_ExpectedFrameRate: o.fps,
            kVTCompressionPropertyKey_AverageBitRate: o.bitrateMbps * 1_000_000,
        ]
        VTSessionSetProperties(vt, propertyDictionary: props as CFDictionary)
        encoder = vt

        let s = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: q)
        try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: q)
        try await s.startCapture()
        stream = s
        let frame = display.frame
        await MainActor.run { startCursor(frame: frame) }
    }

    /// Sanal ekranın ScreenCaptureKit'te görünmesi biraz sürer
    private func waitForDisplay(id: CGDirectDisplayID) async throws -> SCDisplay {
        for _ in 0..<30 {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            if let d = content.displays.first(where: { $0.displayID == id }) { return d }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw err("Sanal ekran hazır olmadı")
    }

    private func err(_ s: String) -> NSError { NSError(domain: "EkranYansit", code: 1, userInfo: [NSLocalizedDescriptionKey: s]) }

    func stop(_ error: String? = nil) {
        q.async { [self] in
            guard conn != nil else { return }
            stream?.stopCapture { _ in }
            stream = nil
            conn?.cancel(); conn = nil
            if let encoder { VTCompressionSessionInvalidate(encoder) }
            encoder = nil
            sentConfig = false
            cursorTimer?.cancel(); cursorTimer = nil
            let vd = virtualDisplay
            virtualDisplay = nil
            DispatchQueue.main.async {
                _ = vd // sanal ekran ana kuyrukta serbest bırakılır, macOS ekranı kaldırır
                self.onStop?(error)
            }
        }
    }

    @MainActor private func startCursor(frame: CGRect) {
        displayFrame = frame
        lastCursorPos = .none
        lastCursorTIFF = nil
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now(), repeating: .milliseconds(8))
        t.setEventHandler { [weak self] in self?.tickCursor() }
        t.resume()
        cursorTimer = t
    }

    /// Ana thread: konum değiştiyse tip 3, imleç şekli değiştiyse (~100 ms'de bir bakılır) tip 4 gönder
    @MainActor private func tickCursor() {
        guard let loc = CGEvent(source: nil)?.location else { return }
        let pos = cursorPosition(loc, in: displayFrame)
        if lastCursorPos == nil || pos.map({ [$0.0, $0.1] }) != lastCursorPos!.map({ [$0.0, $0.1] }) {
            lastCursorPos = .some(pos)
            var d = Data()
            for v in [pos?.0 ?? -1, pos?.1 ?? -1] { withUnsafeBytes(of: v.bitPattern.bigEndian) { d += $0 } }
            q.async { self.send(packet(3, 0, d)) }
        }
        cursorTick += 1
        guard cursorTick % 12 == 0, let c = NSCursor.currentSystem, let tiff = c.image.tiffRepresentation,
              tiff != lastCursorTIFF else { return }
        lastCursorTIFF = tiff
        guard let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        let size = c.image.size
        var d = Data()
        for v in [Float(c.hotSpot.x / size.width), Float(c.hotSpot.y / size.height), Float(size.width / displayFrame.width)] {
            withUnsafeBytes(of: v.bitPattern.bigEndian) { d += $0 }
        }
        q.async { self.send(packet(4, 0, d + png)) }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) { stop(error.localizedDescription) }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sb.isValid else { return }
        let pts = UInt64(max(0, sb.presentationTimeStamp.seconds) * 1_000_000)
        switch type {
        case .screen:
            // SCK ekran değişmeyince "idle" kare yollar; sadece tam kareleri kodla
            guard let info = (CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
                  (info[.status] as? Int) == SCFrameStatus.complete.rawValue,
                  let img = sb.imageBuffer, let encoder else { return }
            VTCompressionSessionEncodeFrame(encoder, imageBuffer: img, presentationTimeStamp: sb.presentationTimeStamp,
                                            duration: .invalid, frameProperties: nil, infoFlagsOut: nil) { [weak self] status, _, out in
                guard status == noErr, let out else { return }
                self?.q.async { self?.sendVideo(out, pts: pts) }
            }
        case .audio:
            sendAudio(sb, pts: pts)
        default: break
        }
    }

    private func sendVideo(_ sb: CMSampleBuffer, pts: UInt64) {
        guard let block = sb.dataBuffer, let fd = sb.formatDescription else { return }
        let notSync = ((CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]])?
            .first?[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false
        var frame = Data()
        if !notSync { // anahtar karenin önüne SPS+PPS koy ki decoder her an toparlanabilsin
            var ps = Data()
            for i in 0..<2 {
                var ptr: UnsafePointer<UInt8>?
                var size = 0
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fd, parameterSetIndex: i, parameterSetPointerOut: &ptr,
                                                                   parameterSetSizeOut: &size, parameterSetCountOut: nil,
                                                                   nalUnitHeaderLengthOut: nil)
                if let ptr { ps += [0, 0, 0, 1]; ps += Data(bytes: ptr, count: size) }
            }
            if !sentConfig {
                let dim = CMVideoFormatDescriptionGetDimensions(fd)
                var cfg = Data()
                withUnsafeBytes(of: UInt32(dim.width).bigEndian) { cfg += $0 }
                withUnsafeBytes(of: UInt32(dim.height).bigEndian) { cfg += $0 }
                send(packet(0, pts, cfg + ps))
                sentConfig = true
            }
            frame = ps
        }
        guard sentConfig else { return } // ilk anahtar kareden önce gelen kareler işe yaramaz
        var raw = Data(count: CMBlockBufferGetDataLength(block))
        raw.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
        send(packet(1, pts, frame + avccToAnnexB(raw)))
    }

    private func sendAudio(_ sb: CMSampleBuffer, pts: UInt64) {
        let list = AudioBufferList.allocate(maximumBuffers: 2)
        defer { free(list.unsafeMutablePointer) }
        var block: CMBlockBuffer?
        let st = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sb, bufferListSizeNeededOut: nil, bufferListOut: list.unsafeMutablePointer,
            bufferListSize: AudioBufferList.sizeInBytes(maximumBuffers: 2), blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil, flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: &block)
        guard st == noErr, list.count > 0 else { return }
        let frames = sb.numSamples
        // SCK Float32 verir: ya kanal başına ayrı tampon (planar) ya da tek tamponda interleaved
        let planar = list.count > 1
        let channels = planar ? list.count : Int(list[0].mNumberChannels)
        let bufs = (0..<list.count).map { list[$0].mData!.assumingMemoryBound(to: Float.self) }
        let pcm = interleaveS16(frames: frames, channels: channels) { c, f in
            planar ? bufs[c][f] : bufs[0][f * channels + c]
        }
        send(packet(2, pts, pcm))
    }

    // shortcut: gönderim kuyruğu sınırsız; yavaş Wi-Fi'da gecikme birikir. Sorun olursa bekleyen bayta göre kare at.
    private func send(_ d: Data) {
        conn?.send(content: d, completion: .contentProcessed { [weak self] e in
            if let e { self?.stop("Bağlantı koptu: \(e)") }
        })
    }
}

// MARK: - adb

@discardableResult
func run(_ cmd: String, _ args: [String]) -> (status: Int32, output: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: cmd)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return (-1, "\(error.localizedDescription)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

/// adb shell için tek tırnaklı güvenli yol
func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
