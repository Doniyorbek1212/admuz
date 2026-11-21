import AVFoundation
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "UzaroVideoNote") {
      let channel = FlutterMethodChannel(name: "uz.sado.app/video", binaryMessenger: registrar.messenger())
      channel.setMethodCallHandler { call, result in
        guard call.method == "cropSquare" else { return result(FlutterMethodNotImplemented) }
        let args = call.arguments as? [String: Any]
        let inputs = args?["inputs"] as? [String] ?? []
        guard !inputs.isEmpty, let output = args?["output"] as? String else {
          return result(FlutterError(code: "bad_args", message: "inputs and output are required", details: nil))
        }
        VideoNoteTranscoder.cropSquare(inputs: inputs, output: output, size: args?["size"] as? Int ?? 480, result: result)
      }
    }
  }
}

/// Round video messages must be square or Telegram delivers them as ordinary videos. Joins the recorded
/// clips (flipping the camera starts a new clip) and center-crops each to size×size, H.264 + AAC.
enum VideoNoteTranscoder {
  static func cropSquare(inputs: [String], output: String, size: Int, result: @escaping FlutterResult) {
    DispatchQueue.global(qos: .userInitiated).async {
      let fail = { (message: String) in
        DispatchQueue.main.async { result(FlutterError(code: "transcode_failed", message: message, details: nil)) }
      }
      let composition = AVMutableComposition()
      guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
        return fail("no video track")
      }
      let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
      let side = CGFloat(size)
      var instructions: [AVMutableVideoCompositionInstruction] = []
      var cursor = CMTime.zero
      for path in inputs {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        guard let source = asset.tracks(withMediaType: .video).first else { continue }
        let range = source.timeRange
        do {
          try videoTrack.insertTimeRange(range, of: source, at: cursor)
          if let audio = asset.tracks(withMediaType: .audio).first {
            try audioTrack?.insertTimeRange(CMTimeRangeGetIntersection(range, otherRange: audio.timeRange), of: audio, at: cursor)
          }
        } catch {
          continue
        }
        // Rotate upright (front and back cameras differ), scale to fill the square, center it.
        let rotation = source.preferredTransform
        let box = CGRect(origin: .zero, size: source.naturalSize).applying(rotation)
        let scale = side / min(abs(box.width), abs(box.height))
        let transform = rotation
          .concatenating(CGAffineTransform(translationX: -box.minX, y: -box.minY))
          .concatenating(CGAffineTransform(scaleX: scale, y: scale))
          .concatenating(CGAffineTransform(translationX: (side - abs(box.width) * scale) / 2, y: (side - abs(box.height) * scale) / 2))
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
        layer.setTransform(transform, at: cursor)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: cursor, duration: range.duration)
        instruction.layerInstructions = [layer]
        instructions.append(instruction)
        cursor = CMTimeAdd(cursor, range.duration)
      }
      if instructions.isEmpty { return fail("no readable clip") }
      let video = AVMutableVideoComposition()
      video.renderSize = CGSize(width: side, height: side)
      video.frameDuration = CMTime(value: 1, timescale: 30)
      video.instructions = instructions
      try? FileManager.default.removeItem(atPath: output)
      guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
        return fail("export unavailable")
      }
      export.outputURL = URL(fileURLWithPath: output)
      export.outputFileType = .mp4
      export.videoComposition = video
      export.shouldOptimizeForNetworkUse = true
      export.exportAsynchronously {
        if export.status == .completed {
          DispatchQueue.main.async { result(output) }
        } else {
          fail(export.error?.localizedDescription ?? "export failed")
        }
      }
    }
  }
}
