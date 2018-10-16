//
//  Options.swift
//
//  Created by Omer Karisman on 2017/08/29.
//

import UIKit
import SceneKit
import AVFoundation

extension SceneKitVideoRecorder {
    public struct Options {
        public var timeScale: Int32
        public var videoSize: CGSize
        public var fps: Int
        public var outputUrl: URL
        public var videoOnlyUrl: URL
        public var fileType: String
        public var codec: String
        public var deleteFileIfExists: Bool
        public var antialiasingMode: SCNAntialiasingMode

        public static var `default`: Options {
            return Options(timeScale: 1000,
                           videoSize: CGSize(width: 720, height: 1280),
                           fps: 60,
                           outputUrl: URL(fileURLWithPath: NSTemporaryDirectory() + "output.mp4"),
                           videoOnlyUrl: URL(fileURLWithPath: NSTemporaryDirectory() + "video.mp4"),
                           fileType: AVFileTypeAppleM4V,
                           codec: AVVideoCodecH264,
                           deleteFileIfExists: true,
                           antialiasingMode: .multisampling4X)
        }

        var assetWriterVideoInputSettings: [String : Any] {
            return [
                AVVideoCodecKey: codec,
                AVVideoWidthKey: videoSize.width,
                AVVideoHeightKey: videoSize.height
            ]
        }

        var sourcePixelBufferAttributes: [String : Any] {
            return [
                kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: kCVPixelFormatType_32ARGB),
                kCVPixelBufferWidthKey as String: videoSize.width,
                kCVPixelBufferHeightKey as String: videoSize.height,
            ]
        }
    }
}

