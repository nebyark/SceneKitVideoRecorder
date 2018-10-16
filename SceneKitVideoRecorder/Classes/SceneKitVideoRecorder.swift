//
//  SceneKitVideoRecorder.swift
//
//  Created by Omer Karisman on 2017/08/29.
//

import UIKit
import SceneKit
import ARKit
import AVFoundation
import CoreImage
import BrightFutures

public class SceneKitVideoRecorder: NSObject {
    private var writer: AVAssetWriter!
    private var videoInput: AVAssetWriterInput!

    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor!
    private var options: Options

    private let frameQueue = DispatchQueue(label: "com.svtek.SceneKitVideoRecorder.frameQueue")
    private let bufferQueue = DispatchQueue(label: "com.svtek.SceneKitVideoRecorder.bufferQueue", attributes: .concurrent)

    private let errorDomain = "com.svtek.SceneKitVideoRecorder"

    private var displayLink: CADisplayLink? = nil

    private var initialTime: CMTime = kCMTimeInvalid
    private var currentTime: CMTime = kCMTimeInvalid

    private var sceneView: SCNView
    private var isPrepared: Bool = false
    public private(set) var isRecording: Bool = false
    private var videoFramesWritten: Bool = false
    private var waitingForPermissions: Bool = false

    private var renderer: SCNRenderer!

    public var updateFrameHandler: ((_ image: UIImage) -> Void)? = nil
    private var finishedCompletionHandler: ((_ url: URL) -> Void)? = nil

    @available(iOS 11.0, *)
    public convenience init(withARSCNView view: ARSCNView, options: Options = .`default`) throws {
        try self.init(scene: view, options: options)
    }

    public init(scene: SCNView, options: Options = .`default`) throws {

        self.sceneView = scene

        self.options = options

        self.isRecording = false
        self.videoFramesWritten = false

        super.init()

        FileController.clearTemporaryDirectory()

        self.prepare()
    }

    private func prepare() {

        self.prepare(with: self.options)
        isPrepared = true

    }

    private func prepare(with options: Options) {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        self.renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = self.sceneView.scene

        initialTime = kCMTimeInvalid

        self.options.videoSize = options.videoSize

        writer = try! AVAssetWriter(outputURL: self.options.videoOnlyUrl, fileType: self.options.fileType)

        self.setupVideo()
    }

    @discardableResult public func cleanUp() -> URL {

        var output = options.outputUrl

        if options.deleteFileIfExists {
            let nameOnly = (options.outputUrl.lastPathComponent as NSString).deletingPathExtension
            let fileExt  = (options.outputUrl.lastPathComponent as NSString).pathExtension
            let tempFileName = NSTemporaryDirectory() + nameOnly + "TMP." + fileExt
            output = URL(fileURLWithPath: tempFileName)

            FileController.move(from: options.outputUrl, to: output)

            FileController.delete(file: self.options.videoOnlyUrl)
        }

        return output
    }

    private func setupVideo() {

        self.videoInput = AVAssetWriterInput(mediaType: AVMediaTypeVideo,
                                             outputSettings: self.options.assetWriterVideoInputSettings)

        self.videoInput.mediaTimeScale = self.options.timeScale

        self.pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput,sourcePixelBufferAttributes: self.options.sourcePixelBufferAttributes)

        writer.add(videoInput)
    }

    @discardableResult public func startWriting() -> Future<Void, NSError> {
        let promise = Promise<Void, NSError>()
        guard !isRecording else {
            promise.failure(NSError(domain: errorDomain, code: ErrorCode.recorderBusy.rawValue, userInfo: nil))
            return promise.future
        }
        isRecording = true

        startDisplayLink()

        guard startInputPipeline() else {
            stopDisplayLink()
            cleanUp()
            promise.failure(NSError(domain: errorDomain, code: ErrorCode.unknown.rawValue, userInfo: nil))
            return promise.future
        }

        promise.success()
        return promise.future
    }

    @discardableResult public func finishWriting() -> Future<URL, NSError> {

        let promise = Promise<URL, NSError>()
        guard isRecording, writer.status == .writing else {
            let error = NSError(domain: errorDomain, code: ErrorCode.notReady.rawValue, userInfo: nil)
            promise.failure(error)
            return promise.future
        }

        videoInput.markAsFinished()

        isRecording = false
        isPrepared = false
        videoFramesWritten = false

        currentTime = kCMTimeInvalid

        writer.finishWriting { [weak self] in

            guard let this = self else { return }

            this.stopDisplayLink()

            FileController.move(from: this.options.videoOnlyUrl, to: this.options.outputUrl)
            let outputUrl = this.cleanUp()
            promise.success(outputUrl)

            this.prepare()
        }
        return promise.future
    }

    private func getCurrentCMTime() -> CMTime {
        return CMTimeMakeWithSeconds(CACurrentMediaTime(), 1000);
    }

    private func getAppendTime() -> CMTime {
        currentTime = getCurrentCMTime() - initialTime
        return currentTime
    }

    private func startDisplayLink() {
        displayLink = CADisplayLink(target: self, selector: #selector(updateDisplayLink))
        displayLink?.preferredFramesPerSecond = options.fps
        displayLink?.add(to: .main, forMode: .commonModes)
    }

    @objc private func updateDisplayLink() {

        frameQueue.async { [weak self] in

            if self?.writer.status == .unknown { return }
            if self?.writer.status == .failed { return }
            guard let input = self?.videoInput, input.isReadyForMoreMediaData else { return }

            self?.renderSnapshot()
        }
    }

    private func startInputPipeline() -> Bool {
        guard writer.status == .unknown else { return false }
        guard writer.startWriting() else { return false }

        writer.startSession(atSourceTime: kCMTimeZero)

        videoInput.requestMediaDataWhenReady(on: frameQueue, using: {})

        return true
    }

    private func renderSnapshot() {

        autoreleasepool {

            let time = CACurrentMediaTime()
            let image = renderer.snapshot(atTime: time, with: self.options.videoSize, antialiasingMode: self.options.antialiasingMode)

            updateFrameHandler?(image)

            guard let pool = self.pixelBufferAdaptor.pixelBufferPool else { print("No pool"); return }

            let pixelBufferTemp = PixelBufferFactory.make(with: image, usingBuffer: pool)

            guard let pixelBuffer = pixelBufferTemp else { print("No buffer"); return }

            guard videoInput.isReadyForMoreMediaData else { print("No ready for media data"); return }

            if videoFramesWritten == false {
                videoFramesWritten = true
                initialTime = getCurrentCMTime()
            }

            let currentTime = getCurrentCMTime()

            guard CMTIME_IS_VALID(currentTime) else { print("No current time"); return }

            let appendTime = getAppendTime()

            guard CMTIME_IS_VALID(appendTime) else { print("No append time"); return }

            bufferQueue.async { [weak self] in
                self?.pixelBufferAdaptor.append(pixelBuffer, withPresentationTime: appendTime)
            }
        }
    }

    private func stopDisplayLink() {

        displayLink?.invalidate()
        displayLink = nil

    }

}
