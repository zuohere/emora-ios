import Foundation
import AVFoundation
import VideoToolbox
import UIKit
import Combine

// MARK: - Video Capture Manager

class VideoCaptureManager: NSObject, ObservableObject {
    // MARK: - Published Properties

    @Published private(set) var isCapturing = false
    @Published private(set) var currentCamera: AVCaptureDevice.Position = .front
    @Published private(set) var session: AVCaptureSession?

    // MARK: - Properties

    private var captureSession: AVCaptureSession?
    private var videoOutput: AVCaptureVideoDataOutput?
    private var videoInput: AVCaptureDeviceInput?

    // Video settings - match backend expectation (1280x720)
    private let videoWidth = 1280
    private let videoHeight = 720
    private let videoFPS = 15

    // H.264 Encoder
    private var compressionSession: VTCompressionSession?
    private var frameIndex: Int = 0
    private let encoderQueue = DispatchQueue(label: "com.emora.videoencoder")

    // SPS/PPS for Annex-B format conversion
    private var spsData: Data?
    private var ppsData: Data?
    private var formatDescription: CMFormatDescription?

    // Callback for encoded frames
    var onVideoFrameEncoded: ((Data, String, Int, Int, Int) -> Void)?

    // Callback for capture errors
    var onCaptureError: ((Error) -> Void)?

    // Serial queue for session management
    private let sessionQueue = DispatchQueue(label: "com.emora.captureSession")

    // Session state tracking
    private var isSessionRunning = false

    // MARK: - Singleton

    static let shared = VideoCaptureManager()

    private override init() {
        super.init()
        setupNotifications()
    }

    // MARK: - Notification Handling

    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleCaptureSessionRuntimeError),
            name: .AVCaptureSessionRuntimeError,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleCaptureSessionWasInterrupted),
            name: .AVCaptureSessionWasInterrupted,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleCaptureSessionInterruptionEnded),
            name: .AVCaptureSessionInterruptionEnded,
            object: nil
        )
    }

    @objc private func handleCaptureSessionRuntimeError(_ notification: Notification) {
        print("[VideoCapture] Runtime error: \(notification.description)")
        onCaptureError?(VideoError.runtimeError)

        // Try to restart session
        sessionQueue.async { [weak self] in
            guard let self = self, let session = self.captureSession else { return }
            session.startRunning()
        }
    }

    @objc private func handleCaptureSessionWasInterrupted(_ notification: Notification) {
        print("[VideoCapture] Session interrupted")
    }

    @objc private func handleCaptureSessionInterruptionEnded(_ notification: Notification) {
        print("[VideoCapture] Interruption ended, resuming...")
        sessionQueue.async { [weak self] in
            guard let self = self, let session = self.captureSession, self.isCapturing else { return }
            session.startRunning()
        }
    }

    // MARK: - Public Methods

    func setupSession() throws {
        let session = AVCaptureSession()
        session.sessionPreset = .high

        // Configure video input
        guard let camera = getCamera(for: currentCamera) else {
            throw VideoError.cameraNotAvailable
        }

        let input = try AVCaptureDeviceInput(device: camera)
        guard session.canAddInput(input) else {
            throw VideoError.cannotAddInput
        }
        session.addInput(input)
        videoInput = input

        // Configure video output
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        output.setSampleBufferDelegate(self, queue: encoderQueue)
        output.alwaysDiscardsLateVideoFrames = true

        guard session.canAddOutput(output) else {
            throw VideoError.cannotAddOutput
        }
        session.addOutput(output)
        videoOutput = output

        // Set video orientation
        if let connection = output.connection(with: .video) {
            connection.videoRotationAngle = 90
            if currentCamera == .front {
                connection.isVideoMirrored = true
            }
        }

        captureSession = session
        self.session = session
    }

    func startPreview() {
        // Just start capture (preview + encoding)
        startCapture()
    }

    func startCapture() {
        guard let session = captureSession else {
            return
        }

        // If already capturing, don't restart
        guard !isCapturing else {
            print("[VideoCapture] Already capturing, skipping start")
            return
        }

        // Reset SPS/PPS for new capture session
        spsData = nil
        ppsData = nil
        formatDescription = nil

        // Setup encoder (only once per run)
        if compressionSession == nil {
            setupEncoder()
        }

        // Start session if not running
        sessionQueue.async { [weak self] in
            guard let self = self else { return }

            // Check if session can run
            if session.isRunning {
                print("[VideoCapture] Session already running")
                self.isSessionRunning = true
            } else {
                // Begin configuration to ensure session is ready
                session.beginConfiguration()
                session.commitConfiguration()

                do {
                    try session.startRunning()
                    self.isSessionRunning = session.isRunning
                    print("[VideoCapture] Session started: \(self.isSessionRunning)")
                } catch {
                    print("[VideoCapture] Failed to start session: \(error)")
                    DispatchQueue.main.async {
                        self.onCaptureError?(VideoError.sessionFailed)
                    }
                    return
                }
            }

            DispatchQueue.main.async {
                self.isCapturing = true
            }
        }
    }

    func stopCapture() {
        guard let session = captureSession else {
            return
        }

        isCapturing = false

        sessionQueue.async { [weak self] in
            guard let self = self else { return }

            if session.isRunning {
                session.stopRunning()
            }
            self.isSessionRunning = false
            self.flushEncoder()

            DispatchQueue.main.async {
                self.frameIndex = 0
                self.spsData = nil
                self.ppsData = nil
                self.formatDescription = nil
            }
        }
    }

    func switchCamera() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }

            let newPosition: AVCaptureDevice.Position = self.currentCamera == .front ? .back : .front

            guard let session = self.captureSession else { return }

            session.beginConfiguration()

            // Remove current input
            if let currentInput = self.videoInput {
                session.removeInput(currentInput)
            }

            // Add new input
            guard let newCamera = self.getCamera(for: newPosition) else {
                session.commitConfiguration()
                return
            }

            do {
                let newInput = try AVCaptureDeviceInput(device: newCamera)
                if session.canAddInput(newInput) {
                    session.addInput(newInput)
                    self.videoInput = newInput

                    // Update video orientation
                    if let connection = self.videoOutput?.connection(with: .video) {
                        connection.videoRotationAngle = 90
                        connection.isVideoMirrored = newPosition == .front
                    }
                }
            } catch {
                // Failed to switch camera
            }

            session.commitConfiguration()

            DispatchQueue.main.async {
                self.currentCamera = newPosition
            }
        }
    }

    // MARK: - Private Methods

    private func getCamera(for position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera],
            mediaType: .video,
            position: position
        )
        return discoverySession.devices.first
    }

    private func setupEncoder() {
        let encoderSpecification: [String: Any] = [
            kVTCompressionPropertyKey_RealTime as String: kCFBooleanTrue!,
            kVTCompressionPropertyKey_ProfileLevel as String: kVTProfileLevel_H264_Baseline_AutoLevel,
            kVTCompressionPropertyKey_AverageBitRate as String: 1000000,
            kVTCompressionPropertyKey_MaxKeyFrameInterval as String: videoFPS * 2,
            kVTCompressionPropertyKey_AllowFrameReordering as String: kCFBooleanFalse!
        ]

        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(videoWidth),
            height: Int32(videoHeight),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: encoderSpecification as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )

        guard status == noErr, let compressionSession = session else {
            // print("[VideoCapture] Failed to create compression session: \(status)")
            return
        }

        VTCompressionSessionPrepareToEncodeFrames(compressionSession)
        self.compressionSession = compressionSession
        //print("[VideoCapture] Compression session created: \(videoWidth)x\(videoHeight) @ \(videoFPS)fps")

        // SPS/PPS will be extracted from the first encoded frame
    }

    private func flushEncoder() {
        if let session = compressionSession {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
            compressionSession = nil
        }
    }

    private func encodeFrame(_ sampleBuffer: CMSampleBuffer) {
        guard let compressionSession = compressionSession,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        let currentFrameIndex = frameIndex
        let isKeyframeRequest = currentFrameIndex % (videoFPS * 2) == 0

        let presentationTimeStamp = CMTime(value: CMTimeValue(currentFrameIndex), timescale: CMTimeScale(videoFPS))

        var infoFlags = VTEncodeInfoFlags()

        // Force IDR frame every 2 seconds
        var frameProperties: [String: Any]? = nil
        if isKeyframeRequest {
            frameProperties = [kVTEncodeFrameOptionKey_ForceKeyFrame as String: true]
        }

        let status = VTCompressionSessionEncodeFrame(
            compressionSession,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: presentationTimeStamp,
            duration: CMTime(value: 1, timescale: CMTimeScale(videoFPS)),
            frameProperties: frameProperties as CFDictionary?,
            infoFlagsOut: &infoFlags
        ) { [weak self] status, infoFlags, sampleBuffer in
            guard status == noErr,
                  let sampleBuffer = sampleBuffer,
                  let self = self else {
                return
            }

            self.processEncodedFrame(sampleBuffer, frameIndex: currentFrameIndex)
        }

        if status != noErr {
            // print("[VideoCapture] Encode frame FAILED: \(status)")
        }

        frameIndex += 1
    }

    // MARK: - SPS/PPS Extraction and Annex-B Conversion

    private func extractSPSPPS(from formatDesc: CMFormatDescription) {
        guard spsData == nil || ppsData == nil else { return }

        var parameterSetCount: Int = 0
        var nalUnitHeaderLength: Int32 = 0

        let countStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDesc,
            parameterSetIndex: 0,
            parameterSetPointerOut: nil,
            parameterSetSizeOut: nil,
            parameterSetCountOut: &parameterSetCount,
            nalUnitHeaderLengthOut: &nalUnitHeaderLength
        )

        guard countStatus == noErr, parameterSetCount >= 2 else {
            return
        }

        // Extract SPS
        var spsSize: Int = 0
        var spsPointer: UnsafePointer<UInt8>?

        var status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDesc,
            parameterSetIndex: 0,
            parameterSetPointerOut: &spsPointer,
            parameterSetSizeOut: &spsSize,
            parameterSetCountOut: nil,
            nalUnitHeaderLengthOut: nil
        )

        if status == noErr, let spsPointer = spsPointer {
            spsData = Data(bytes: spsPointer, count: spsSize)
            //print("[VideoCapture] SPS extracted: \(spsSize) bytes")
        }

        // Extract PPS
        var ppsSize: Int = 0
        var ppsPointer: UnsafePointer<UInt8>?

        status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDesc,
            parameterSetIndex: 1,
            parameterSetPointerOut: &ppsPointer,
            parameterSetSizeOut: &ppsSize,
            parameterSetCountOut: nil,
            nalUnitHeaderLengthOut: nil
        )

        if status == noErr, let ppsPointer = ppsPointer {
            ppsData = Data(bytes: ppsPointer, count: ppsSize)
            //print("[VideoCapture] PPS extracted: \(ppsSize) bytes")
        }
    }

    /// Convert AVCC format to Annex-B format
    private func convertToAnnexB(data: Data, isKeyframe: Bool) -> Data {
        var result = Data()

        // 4-byte start code
        let startCode: [UInt8] = [0x00, 0x00, 0x00, 0x01]

        // Prepend SPS/PPS when available
        if let sps = spsData, let pps = ppsData {
            result.append(contentsOf: startCode)
            result.append(sps)
            result.append(contentsOf: startCode)
            result.append(pps)
        }

        // Convert AVCC to Annex-B
        var offset = 0
        while offset + 4 <= data.count {
            let length = UInt32(data[offset]) << 24 |
                         UInt32(data[offset + 1]) << 16 |
                         UInt32(data[offset + 2]) << 8 |
                         UInt32(data[offset + 3])

            result.append(contentsOf: startCode)

            let naluStart = offset + 4
            let naluEnd = min(naluStart + Int(length), data.count)

            if naluEnd > naluStart {
                result.append(data.subdata(in: naluStart..<naluEnd))
            }

            offset = naluEnd
        }

        return result
    }

    private func processEncodedFrame(_ sampleBuffer: CMSampleBuffer, frameIndex: Int) {
        // Get format description
        guard let newFormatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            return
        }

        // Check if keyframe
        var isKeyframe = false
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
           let attachment = attachments.first {
            isKeyframe = !(attachment[kCMSampleAttachmentKey_NotSync] as? Bool ?? true)
        }

        // Extract SPS/PPS if needed
        if isKeyframe || spsData == nil || ppsData == nil {
            if formatDescription == nil || !CMFormatDescriptionEqual(newFormatDesc, otherFormatDescription: formatDescription) {
                formatDescription = newFormatDesc
                extractSPSPPS(from: newFormatDesc)
            }
        }

        // Get raw data
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            return
        }

        let length = CMBlockBufferGetDataLength(dataBuffer)
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(
            dataBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: nil,
            dataPointerOut: &dataPointer
        )

        guard status == kCMBlockBufferNoErr,
              let pointer = dataPointer,
              length > 0 else {
            return
        }

        let rawData = Data(bytes: pointer, count: length)

        // Convert to Annex-B
        let annexBData = convertToAnnexB(data: rawData, isKeyframe: isKeyframe)

        let timestamp = ISO8601DateFormatter().string(from: Date())

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.onVideoFrameEncoded?(annexBData, timestamp, frameIndex, self.videoWidth, self.videoHeight)
        }
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension VideoCaptureManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if isCapturing {
            encodeFrame(sampleBuffer)
        }
    }
}

// MARK: - Video Error

enum VideoError: Error, LocalizedError {
    case cameraNotAvailable
    case cannotAddInput
    case cannotAddOutput
    case encodingFailed
    case runtimeError
    case sessionFailed

    var errorDescription: String? {
        switch self {
        case .cameraNotAvailable:
            return "Camera is not available"
        case .cannotAddInput:
            return "Cannot add camera input"
        case .cannotAddOutput:
            return "Cannot add video output"
        case .encodingFailed:
            return "Video encoding failed"
        case .runtimeError:
            return "Camera runtime error"
        case .sessionFailed:
            return "Camera session failed to start"
        }
    }
}
