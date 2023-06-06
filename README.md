KSAssetExportSession
======================

`AVAssetExportSession` drop-in replacement with customizable audio&amp;video settings.

You want the ease of use of `AVAssetExportSession` but default provided presets doesn't fit your needs? You then began to read documentation for `AVAssetWriter`, `AVAssetWriterInput`, `AVAssetReader`, `AVAssetReaderVideoCompositionOutput`, `AVAssetReaderAudioMixOutput`… and you went out of aspirin? `SDAVAssetExportSession` is a rewrite of `AVAssetExportSession` on top of `AVAssetReader*` and `AVAssetWriter*`. Unlike `AVAssetExportSession`, you are not limited to a set of presets – you have full access over audio and video settings.


Usage Example
-------------

``` swift
let asset = AVAsset(url: Bundle(for: type(of: self)).url(forResource: "test", withExtension: "MOV")!)
let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    .appendingPathComponent(ProcessInfo().globallyUniqueString)
    .appendingPathExtension("mp4")
let compressionDict: [String: Any] = [
    AVVideoAverageBitRateKey: NSNumber(integerLiteral: 2_000_000),
    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
    AVVideoH264EntropyModeKey: AVVideoH264EntropyModeCABAC,
    AVVideoExpectedSourceFrameRateKey: NSNumber(integerLiteral: 24),
]
let videoOutputConfiguration = [
    AVVideoCodecKey: AVVideoCodecH264,
    AVVideoWidthKey: NSNumber(integerLiteral: 540),
    AVVideoHeightKey: NSNumber(integerLiteral: 960),
    AVVideoScalingModeKey: AVVideoScalingModeResizeAspectFill,
    AVVideoCompressionPropertiesKey: compressionDict,
    ] as [String: Any]
let audioOutputConfiguration = [
    AVFormatIDKey: kAudioFormatMPEG4AAC,
    AVEncoderBitRateKey: NSNumber(integerLiteral: 64000),
    AVNumberOfChannelsKey: NSNumber(integerLiteral: 1),
    AVSampleRateKey: NSNumber(value: Float(44100)),
    ] as [String: Any]
let encoder = asset.export(outputURL: tmpURL, videoOutputConfiguration: videoOutputConfiguration, audioOutputConfiguration: audioOutputConfiguration, progressHandler: { progress in
    print(progress)
}) { status, error in
    switch status {
    case .completed:
        print("SessionExporter, export completed, \(tmpURL.description)")
    case .cancelled:
        print("SessionExporter, export cancelled")
    case .failed:
        print("SessionExporter, failed to export, \(error.debugDescription)")
    case .exporting:
        fallthrough
    case .waiting:
        fallthrough
    default:
        print("SessionExporter, did not complete")
    }
}
```
