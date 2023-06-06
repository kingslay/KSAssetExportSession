import AVFoundation
import Foundation
/// KSAssetExportSession, export and transcode media in Swift
open class KSAssetExportSession: NSObject {
    // private instance vars
    private let asset: AVAsset
    private let inputQueue: DispatchQueue
    private var writer: AVAssetWriter?
    private var reader: AVAssetReader?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var audioOutput: AVAssetReaderOutput?
    private var progressHandler: ProgressHandler?
    private var renderHandler: RenderHandler?
    private var completionHandler: CompletionHandler?
    private var duration: TimeInterval = 0
    public private(set) var progress: Float = 0
    /// Input asset for export, provided when initialized.
    public var synchronous = false
    public var writerInput: [AVAssetWriterInput]?
    public var videoOutput: AVAssetReaderOutput?
    /// Enables audio mixing and parameters for the session.
    public var audioMix: AVAudioMix?

    /// Output file location for the session.
    public var outputURL: URL?

    /// Output file type. UTI string defined in `AVMediaFormat.h`.
    public var outputFileType = AVFileType.mp4

    /// Time range or limit of an export from `kCMTimeZero` to `kCMTimePositiveInfinity`
    public var timeRange: CMTimeRange

    /// Indicates if an export session should expect media data in real time.
    public var expectsMediaDataInRealTime = false

    /// Indicates if an export should be optimized for network use.
    public var optimizeForNetworkUse: Bool = false

    public var audioTimePitchAlgorithm: AVAudioTimePitchAlgorithm?
    /// Metadata to be added to an export.
    public var metadata: [AVMetadataItem]?

    /// Video output configuration dictionary, using keys defined in `<AVFoundation/AVVideoSettings.h>`
    public var videoOutputConfiguration: [String: Any]?

    /// Audio output configuration dictionary, using keys defined in `<AVFoundation/AVAudioSettings.h>`
    public var audioOutputConfiguration: [String: Any]?

    /// Export session status state.
    public var status: AVAssetExportSession.Status {
        guard let writer = self.writer else {
            return .unknown
        }
        switch writer.status {
        case .writing:
            return .exporting
        case .failed:
            return .failed
        case .completed:
            return .completed
        case .cancelled:
            return .cancelled
        case .unknown:
            return .unknown
        @unknown default:
            return .unknown
        }
    }

    @objc public var readerStatus: AVAssetReader.Status {
        return reader?.status ?? .unknown
    }

    // MARK: - object lifecycle

    /// Initializes a session with an asset to export.
    ///
    /// - Parameter asset: The asset to export.
    public init(withAsset asset: AVAsset) {
        self.asset = asset
        timeRange = CMTimeRange(start: .zero, end: .positiveInfinity)
        inputQueue = DispatchQueue(label: "KSSessionExporterInputQueue", target: DispatchQueue.global())
        super.init()
    }

    deinit {
        self.writer = nil
        self.reader = nil
        self.pixelBufferAdaptor = nil
        self.videoOutput = nil
        self.audioOutput = nil
    }
}

// MARK: - export

extension KSAssetExportSession {
    /// Completion handler type for when an export finishes.
    public typealias CompletionHandler = (_ status: AVAssetExportSession.Status, _ erro: Error?) -> Void

    /// Progress handler type
    public typealias ProgressHandler = (_ progress: Float) -> Void

    /// Render handler type for frame processing
    public typealias RenderHandler = (_ renderFrame: CVPixelBuffer, _ presentationTime: CMTime, _ resultingBuffer: CVPixelBuffer) -> Void

    /// Initiates an export session.
    ///
    /// - Parameter completionHandler: Handler called when an export session completes.
    /// - Throws: Failure indication thrown when an error has occurred during export.
    public func export(renderHandler: RenderHandler? = nil, progressHandler: ProgressHandler? = nil, completionHandler: CompletionHandler? = nil) throws {
        cancelExport()
        guard let outputURL = outputURL, let videoOutput = self.videoOutput, videoOutputConfiguration?.validate() == true else {
            throw NSError(domain: AVFoundationErrorDomain, code: AVError.exportFailed.rawValue, userInfo: [NSLocalizedDescriptionKey: "setup failure"])
        }
        let videoTrack = asset.tracks(withMediaType: .video).first { $0.isPlayable == true }
        guard videoTrack != nil else {
            throw NSError(domain: AVFoundationErrorDomain, code: AVError.exportFailed.rawValue, userInfo: [NSLocalizedDescriptionKey: "video can't play"])
        }
        outputURL.remove()
        self.progressHandler = progressHandler
        self.renderHandler = renderHandler
        self.completionHandler = completionHandler
        reader = try AVAssetReader(asset: asset)
        writer = try AVAssetWriter(outputURL: outputURL, fileType: outputFileType)
        guard let reader = reader, let writer = writer else {
            return
        }
        reader.timeRange = timeRange
        writer.shouldOptimizeForNetworkUse = optimizeForNetworkUse
        if let metadata = self.metadata {
            writer.metadata = metadata
        }

        if timeRange.duration.isValid, !timeRange.duration.isPositiveInfinity {
            duration = CMTimeGetSeconds(timeRange.duration)
        } else {
            duration = CMTimeGetSeconds(asset.duration)
        }

        // video
        if reader.canAdd(videoOutput) {
            reader.add(videoOutput)
        }
        guard writer.canApply(outputSettings: videoOutputConfiguration, forMediaType: .video) else {
            throw NSError(domain: AVFoundationErrorDomain, code: AVError.exportFailed.rawValue, userInfo: [NSLocalizedDescriptionKey: "setup failure"])
        }

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoOutputConfiguration)
        videoInput.expectsMediaDataInRealTime = expectsMediaDataInRealTime
        guard writer.canAdd(videoInput) else {
            throw NSError(domain: AVFoundationErrorDomain, code: AVError.exportFailed.rawValue, userInfo: [NSLocalizedDescriptionKey: "Can't add video input"])
        }
        writer.add(videoInput)
        if renderHandler != nil {
            pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, output: videoOutput)
        }

        // audio
        let audioTracks = asset.tracks(withMediaType: .audio)
        if audioTracks.count > 0 {
            let (audioOutput, audioInput) = audioOutputInput(audioTracks: audioTracks)
            if reader.canAdd(audioOutput) {
                reader.add(audioOutput)
                self.audioOutput = audioOutput
                if writer.canAdd(audioInput) {
                    writer.add(audioInput)
                }
            }
        }
        writerInput?.filter { writer.canAdd($0) }.forEach { writer.add($0) }
        // export
        guard writer.startWriting() else {
            throw NSError(domain: AVFoundationErrorDomain, code: AVError.exportFailed.rawValue, userInfo: [NSLocalizedDescriptionKey: "can't startWriting"])
        }
        guard reader.startReading() else {
            throw NSError(domain: AVFoundationErrorDomain, code: AVError.exportFailed.rawValue, userInfo: [NSLocalizedDescriptionKey: "can't startReading"])
        }
        writer.startSession(atSourceTime: timeRange.start)

        let audioSemaphore = DispatchSemaphore(value: 0)
        let videoSemaphore = DispatchSemaphore(value: 0)
        videoInput.requestMediaDataWhenReady(on: inputQueue) { [weak self] in
            guard let self = self, self.encode(readySamplesFromReaderOutput: videoOutput, toWriterInput: videoInput) else {
                videoSemaphore.signal()
                return
            }
        }
        if let audioOutput = self.audioOutput, let audioInput = writer.inputs.first(where: { $0.mediaType == .audio }) {
            audioInput.requestMediaDataWhenReady(on: inputQueue) { [weak self] in
                guard let self = self, self.encode(readySamplesFromReaderOutput: audioOutput, toWriterInput: audioInput) else {
                    audioSemaphore.signal()
                    return
                }
            }
        } else {
            audioSemaphore.signal()
        }
        if synchronous {
            audioSemaphore.wait()
            videoSemaphore.wait()
            finish()
        } else {
            DispatchQueue.global().async { [weak self] in
                audioSemaphore.wait()
                videoSemaphore.wait()
                self?.finish()
            }
        }
    }

    /// Cancels any export in progress.
    @objc public func cancelExport() {
        if let writer = writer {
            inputQueue.async {
                writer.cancelWriting()
            }
        }
        if let reader = reader {
            inputQueue.async {
                reader.cancelReading()
            }
        }
    }
}

// MARK: - private funcs

extension KSAssetExportSession {
    private func audioOutputInput(audioTracks: [AVAssetTrack]) -> (AVAssetReaderOutput, AVAssetWriterInput) {
        let audioOutput = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: nil)
        audioOutput.alwaysCopiesSampleData = false
        if let audioTimePitchAlgorithm = audioTimePitchAlgorithm {
            audioOutput.audioTimePitchAlgorithm = audioTimePitchAlgorithm
        }
        audioOutput.audioMix = audioMix
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioOutputConfiguration)
        audioInput.expectsMediaDataInRealTime = expectsMediaDataInRealTime
        return (audioOutput, audioInput)
    }

    // called on the inputQueue
    private func encode(readySamplesFromReaderOutput output: AVAssetReaderOutput, toWriterInput input: AVAssetWriterInput) -> Bool {
        while input.isReadyForMoreMediaData {
            guard let sampleBuffer = output.copyNextSampleBuffer() else {
                input.markAsFinished()
                return false
            }
            guard reader?.status == .reading, writer?.status == .writing else {
                return false
            }
            if output.mediaType == .video {
                let lastSamplePresentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer) - timeRange.start
                let progress = duration == 0 ? 1 : Float(lastSamplePresentationTime.seconds / duration)
                updateProgress(progress: progress)
                if let renderHandler = renderHandler, let pixelBufferAdaptor = pixelBufferAdaptor, let pixelBufferPool = pixelBufferAdaptor.pixelBufferPool, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
                    var toRenderBuffer: CVPixelBuffer?
                    let result = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pixelBufferPool, &toRenderBuffer)
                    if result == kCVReturnSuccess, let toBuffer = toRenderBuffer {
                        renderHandler(pixelBuffer, lastSamplePresentationTime, toBuffer)
                        if pixelBufferAdaptor.append(toBuffer, withPresentationTime: lastSamplePresentationTime) {
                            continue
                        } else {
                            return false
                        }
                    }
                }
            }
            guard input.append(sampleBuffer) else {
                return false
            }
        }
        return true
    }

    private func updateProgress(progress: Float) {
        willChangeValue(forKey: "progress")
        self.progress = progress
        didChangeValue(forKey: "progress")
        progressHandler?(progress)
    }

    private func finish() {
        if reader?.status == .cancelled || writer?.status == .cancelled {
            complete()
        } else if writer?.status == .failed {
            complete()
        } else if reader?.status == .failed {
            writer?.cancelWriting()
            complete()
        } else {
            writer?.finishWriting { [weak self] in self?.complete() }
        }
    }

    private func complete() {
        if status == .failed || status == .cancelled {
            outputURL?.remove()
        }
        completionHandler?(status, writer?.error ?? reader?.error)
        completionHandler = nil
    }

    private func reset() {
        progress = 0
        writer = nil
        reader = nil
        pixelBufferAdaptor = nil
        videoOutput = nil
        audioOutput = nil
        progressHandler = nil
        renderHandler = nil
        completionHandler = nil
    }
}

// MARK: - AVAsset extension

extension AVAsset {
    /// Initiates a NextLevelSessionExport on the asset
    ///
    /// - Parameters:
    ///   - outputURL: location of resulting file
    ///   - videoInputConfiguration: video input configuration
    ///   - videoOutputConfiguration: video output configuration
    ///   - audioOutputConfiguration: audio output configuration
    ///   - progressHandler: progress fraction handler
    ///   - completionHandler: completion handler
    @objc public func export(outputURL: URL,
                             videoOutputConfiguration: [String: Any],
                             audioOutputConfiguration: [String: Any],
                             audioTimePitchAlgorithm: AVAudioTimePitchAlgorithm? = nil,
                             progressHandler: KSAssetExportSession.ProgressHandler? = nil,
                             completionHandler: @escaping KSAssetExportSession.CompletionHandler) -> KSAssetExportSession {
        let exporter = KSAssetExportSession(withAsset: self)
        exporter.outputURL = outputURL
        exporter.optimizeForNetworkUse = true
        exporter.videoOutputConfiguration = videoOutputConfiguration
        exporter.audioOutputConfiguration = audioOutputConfiguration
        exporter.audioTimePitchAlgorithm = audioTimePitchAlgorithm
        let videoOutput = AVAssetReaderVideoCompositionOutput(videoTracks: tracks(withMediaType: .video), videoSettings: nil)
        videoOutput.alwaysCopiesSampleData = false
        videoOutput.videoComposition = makeVideoComposition(videoOutputConfiguration: videoOutputConfiguration)
        exporter.videoOutput = videoOutput
        do {
            try exporter.export(progressHandler: progressHandler, completionHandler: completionHandler)
        } catch let error as NSError? {
            completionHandler(exporter.status, error)
        }
        return exporter
    }

    public func quickTimeMov(outputURL: URL, assetIdentifier: String,
                             completionHandler: KSAssetExportSession.CompletionHandler? = nil) -> KSAssetExportSession {
        let exporter = KSAssetExportSession(withAsset: self)
        guard let videoTrack = tracks(withMediaType: .video).first else {
            completionHandler?(.failed, NSError(domain: AVFoundationErrorDomain, code: AVError.exportFailed.rawValue, userInfo: [NSLocalizedDescriptionKey: "haven't video track"]))
            return exporter
        }
        exporter.outputFileType = .mov
        exporter.outputURL = outputURL
        exporter.videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: kCVPixelFormatType_32BGRA)])
        exporter.videoOutputConfiguration = [
            AVVideoCodecKey: AVVideoCodecH264 as AnyObject,
            AVVideoWidthKey: videoTrack.naturalSize.width as AnyObject,
            AVVideoHeightKey: videoTrack.naturalSize.height as AnyObject,
        ]
        exporter.metadata = [AVMutableMetadataItem(assetIdentifier: assetIdentifier)]
        exporter.writerInput = [AVAssetWriterInput.makeMetadataAdapter()]
        exporter.synchronous = true
        do {
            try exporter.export(progressHandler: nil, completionHandler: completionHandler)
        } catch let error as NSError? {
            completionHandler?(exporter.status, error)
        }
        return exporter
    }

    fileprivate func makeVideoComposition(videoOutputConfiguration: [String: Any]?) -> AVMutableVideoComposition {
        let videoComposition = AVMutableVideoComposition()
        guard let videoTrack = tracks(withMediaType: .video).first else {
            return videoComposition
        }
        // determine the framerate
        var frameRate: Float = 24
        if let videoCompressionConfiguration = videoOutputConfiguration?[AVVideoCompressionPropertiesKey] as? [String: Any] {
            if let trackFrameRate = videoCompressionConfiguration[AVVideoExpectedSourceFrameRateKey] as? NSNumber {
                frameRate = trackFrameRate.floatValue
            }
        } else {
            frameRate = videoTrack.nominalFrameRate
        }
        videoComposition.frameDuration = CMTimeMake(value: 1, timescale: Int32(frameRate))
        // determine the appropriate size and transform
        if let videoConfiguration = videoOutputConfiguration {
            let videoWidth = videoConfiguration[AVVideoWidthKey] as? NSNumber
            let videoHeight = videoConfiguration[AVVideoHeightKey] as? NSNumber
            let targetSize = CGSize(width: videoWidth!.intValue, height: videoHeight!.intValue)
            var naturalSize = videoTrack.naturalSize
            var transform = videoTrack.preferredTransform
            if transform.ty == -560 {
                transform.ty = 0
            }

            if transform.tx == -560 {
                transform.tx = 0
            }
            let videoAngleInDegrees = atan2(transform.b, transform.a) * 180 / .pi
            if videoAngleInDegrees == 90 || videoAngleInDegrees == -90 {
                naturalSize = CGSize(width: naturalSize.height, height: naturalSize.width)
            }
            videoComposition.renderSize = naturalSize

            // center the video
            var ratio: CGFloat = 0
            let xRatio: CGFloat = targetSize.width / naturalSize.width
            let yRatio: CGFloat = targetSize.height / naturalSize.height
            ratio = min(xRatio, yRatio)
            let postWidth = naturalSize.width * ratio
            let postHeight = naturalSize.height * ratio
            let transX = (targetSize.width - postWidth) * 0.5
            let transY = (targetSize.height - postHeight) * 0.5

            var matrix = CGAffineTransform(translationX: transX / xRatio, y: transY / yRatio)
            matrix = matrix.scaledBy(x: ratio / xRatio, y: ratio / yRatio)
            transform = transform.concatenating(matrix)
            // make the composition
            let compositionInstruction = AVMutableVideoCompositionInstruction()
            compositionInstruction.timeRange = CMTimeRange(start: .zero, duration: duration)

            let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
            layerInstruction.setTransform(transform, at: .zero)
            compositionInstruction.layerInstructions = [layerInstruction]
            videoComposition.instructions = [compositionInstruction]
        }
        return videoComposition
    }
}

extension AVAssetWriterInput {
    fileprivate static func makeMetadataAdapter() -> AVAssetWriterInput {
        let spec = [
            kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier:
            "mdta/com.apple.quicktime.still-image-time",
            kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType:
            "com.apple.metadata.datatype.int8",
        ]
        var desc: CMFormatDescription?
        CMMetadataFormatDescriptionCreateWithMetadataSpecifications(allocator: kCFAllocatorDefault, metadataType: kCMMetadataFormatType_Boxed, metadataSpecifications: [spec] as CFArray, formatDescriptionOut: &desc)
        let input = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil, sourceFormatHint: desc)
        let adapter = AVAssetWriterInputMetadataAdaptor(assetWriterInput: input)
        adapter.append(AVTimedMetadataGroup(items: [AVMutableMetadataItem.makeStillImageTime()], timeRange: CMTimeRange(start: CMTime(value: 0, timescale: 1000), duration: CMTime(value: 200, timescale: 3000))))
        return adapter.assetWriterInput
    }
}

extension AVMutableMetadataItem {
    fileprivate convenience init(assetIdentifier: String) {
        self.init()
        key = "com.apple.quicktime.content.identifier" as NSCopying & NSObjectProtocol
        keySpace = AVMetadataKeySpace(rawValue: "mdta")
        value = assetIdentifier as NSCopying & NSObjectProtocol
        dataType = "com.apple.metadata.datatype.UTF-8"
    }

    fileprivate static func makeStillImageTime() -> AVMutableMetadataItem {
        let item = AVMutableMetadataItem()
        item.key = "com.apple.quicktime.still-image-time" as NSCopying & NSObjectProtocol
        item.keySpace = AVMetadataKeySpace(rawValue: "mdta")
        item.value = -1 as NSCopying & NSObjectProtocol
        item.dataType = "com.apple.metadata.datatype.int8"
        return item
    }
}

extension Dictionary where Key == String, Value == Any {
    fileprivate mutating func validate() -> Bool {
        if !keys.contains(AVVideoCodecKey) {
            debugPrint("KSAssetExportSession, warning a video output configuration codec wasn't specified")
            if #available(iOS 11.0, *) {
                self[AVVideoCodecKey] = AVVideoCodecType.h264
            } else {
                self[AVVideoCodecKey] = AVVideoCodecH264
            }
        }
        let videoWidth = self[AVVideoWidthKey] as? NSNumber
        let videoHeight = self[AVVideoHeightKey] as? NSNumber
        if videoWidth == nil || videoHeight == nil {
            return false
        }
        return true
    }
}

extension URL {
    fileprivate func remove() {
        if FileManager.default.fileExists(atPath: path) {
            do {
                try FileManager.default.removeItem(at: self)
            } catch {
                debugPrint("KSAssetExportSession, failed to delete file at \(self)")
            }
        }
    }
}

extension AVAssetWriterInputPixelBufferAdaptor {
    fileprivate convenience init(assetWriterInput input: AVAssetWriterInput, output: AVAssetReaderOutput) {
        var pixelBufferAttrib: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: NSNumber(integerLiteral: Int(kCVPixelFormatType_32RGBA)),
            "IOSurfaceOpenGLESTextureCompatibility": NSNumber(booleanLiteral: true),
            "IOSurfaceOpenGLESFBOCompatibility": NSNumber(booleanLiteral: true),
        ]
        if let videoOutput = output as? AVAssetReaderVideoCompositionOutput, let videoComposition = videoOutput.videoComposition {
            pixelBufferAttrib[kCVPixelBufferWidthKey as String] = NSNumber(integerLiteral: Int(videoComposition.renderSize.width))
            pixelBufferAttrib[kCVPixelBufferHeightKey as String] = NSNumber(integerLiteral: Int(videoComposition.renderSize.height))
        }
        self.init(assetWriterInput: input, sourcePixelBufferAttributes: pixelBufferAttrib)
    }
}
