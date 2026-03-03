import Foundation
import AVFoundation
import AudioToolbox
import Combine
import CoreAudio

// MARK: - Audio Capture Manager

class AudioCaptureManager: NSObject, ObservableObject {
    // MARK: - Published Properties

    @Published private(set) var isCapturing = false

    // MARK: - Properties

    private var audioEngine: AVAudioEngine?
    private var inputNode: AVAudioInputNode?

    // Audio settings from client.py
    let sampleRate: Int = 24000
    let channels: Int = 1
    let chunkSize: Int = 512

    // AAC Encoder
    private var audioConverter: AudioConverterRef?
    private var aacBuffer: UnsafeMutablePointer<UInt8>?
    private var aacBufferSize: UInt32 = 0

    // Callback for encoded audio data
    var onAudioData: ((Data, String, Int) -> Void)?

    // MARK: - Singleton

    static let shared = AudioCaptureManager()

    private override init() {
        super.init()
    }

    // MARK: - Public Methods

    func setupSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetooth])
        try session.setPreferredSampleRate(Double(sampleRate))
        try session.setPreferredIOBufferDuration(Double(chunkSize) / Double(sampleRate))
        try session.setActive(true)

        audioEngine = AVAudioEngine()
        guard let engine = audioEngine else {
            throw AudioError.engineNotAvailable
        }

        inputNode = engine.inputNode
        guard let inputNode = inputNode else {
            throw AudioError.inputNotAvailable
        }

        let inputFormat = inputNode.outputFormat(forBus: 0)

        // Setup AAC encoder
        try setupAACEncoder(inputFormat: inputFormat)

        // Install tap on input node
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                   sampleRate: inputFormat.sampleRate,
                                   channels: AVAudioChannelCount(channels),
                                   interleaved: true)!

        inputNode.installTap(onBus: 0, bufferSize: UInt32(chunkSize), format: format) { [weak self] buffer, time in
            self?.processAudioBuffer(buffer)
        }
    }

    func startCapture() {
        guard let engine = audioEngine, !engine.isRunning else {
            return
        }

        do {
            try engine.start()
            DispatchQueue.main.async { [weak self] in
                self?.isCapturing = true
            }
            // print("[AudioCapture] AAC encoder started")
        } catch {
            // print("[AudioCapture] Failed to start engine: \(error)")
        }
    }

    func stopCapture() {
        guard let engine = audioEngine, engine.isRunning else {
            return
        }

        inputNode?.removeTap(onBus: 0)
        audioEngine?.stop()

        // Clean up AAC encoder
        if let converter = audioConverter {
            AudioConverterDispose(converter)
            audioConverter = nil
        }

        if let buffer = aacBuffer {
            free(buffer)
            aacBuffer = nil
        }

        DispatchQueue.main.async { [weak self] in
            self?.isCapturing = false
        }
        // print("[AudioCapture] Stopped")
    }

    // MARK: - Private Methods

    private var chunkIndex: Int = 0

    private func setupAACEncoder(inputFormat: AVAudioFormat) throws {
        // Create output format (AAC)
        var outputFormat = AudioStreamBasicDescription(
            mSampleRate: Double(sampleRate),
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 1024,
            mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 0,
            mReserved: 0
        )

        // Create input format (PCM Int16)
        var inputDescription = AudioStreamBasicDescription(
            mSampleRate: inputFormat.sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(channels * 2),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(channels * 2),
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 16,
            mReserved: 0
        )

        var converter: AudioConverterRef?
        let status = AudioConverterNew(&inputDescription, &outputFormat, &converter)

        guard status == noErr, let conv = converter else {
            // print("[AudioCapture] Failed to create AAC encoder: \(status)")
            throw AudioError.encoderSetupFailed
        }

        audioConverter = conv

        // Set bit rate
        var bitRate: UInt32 = 64000
        AudioConverterSetProperty(conv,
                                   kAudioConverterEncodeBitRate,
                                   UInt32(MemoryLayout<UInt32>.size),
                                   &bitRate)

        // Allocate AAC buffer
        aacBufferSize = 1024 * 4 // 4KB should be enough for AAC
        aacBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: Int(aacBufferSize))

        // print("[AudioCapture] AAC encoder setup complete")
    }

    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard isCapturing,
              let converter = audioConverter,
              let aacBuffer = aacBuffer else {
            return
        }

        // Convert PCM to AAC
        guard let int16Data = buffer.int16ChannelData else {
            // print("[AudioCapture] Failed to get int16 channel data")
            return
        }

        let frameCount = Int(buffer.frameLength)
        let inputData = int16Data[0]

        var inputDataRef = inputData

        var outputBuffer = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: UInt32(channels),
                mDataByteSize: aacBufferSize,
                mData: aacBuffer
            )
        )

        var ioOutputDataPacketSize: UInt32 = 1

        let status = AudioConverterFillComplexBuffer(
            converter,
            { (converter, ioNumberDataPackets, ioData, outDataPacketDescription, userData) -> OSStatus in
                guard let userData = userData?.assumingMemoryBound(to: UnsafeMutablePointer<Int16>.self) else {
                    return -1
                }

                let dataSize = min(ioNumberDataPackets.pointee * 2, 1024)
                ioData.pointee.mBuffers.mData = UnsafeMutableRawPointer(userData.pointee)
                ioData.pointee.mBuffers.mDataByteSize = dataSize
                ioData.pointee.mBuffers.mNumberChannels = 1
                ioNumberDataPackets.pointee = dataSize / 2

                return noErr
            },
            &inputDataRef,
            &ioOutputDataPacketSize,
            &outputBuffer,
            nil
        )

        if status == noErr && ioOutputDataPacketSize > 0 {
            let aacData = Data(bytes: aacBuffer, count: Int(outputBuffer.mBuffers.mDataByteSize))
            let timestamp = ISO8601DateFormatter().string(from: Date())
            let currentIndex = chunkIndex
            chunkIndex += 1

            // print("[AudioCapture] AAC encoded - chunkIndex: \(currentIndex), size: \(aacData.count) bytes")

            // Send AAC data
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.onAudioData?(aacData, timestamp, currentIndex)
            }
        }
    }
}

// MARK: - Audio Error

enum AudioError: Error, LocalizedError {
    case engineNotAvailable
    case inputNotAvailable
    case encoderSetupFailed

    var errorDescription: String? {
        switch self {
        case .engineNotAvailable:
            return "Audio engine is not available"
        case .inputNotAvailable:
            return "Audio input is not available"
        case .encoderSetupFailed:
            return "Failed to setup AAC encoder"
        }
    }
}
