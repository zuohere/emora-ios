# iOS 端代码架构与数据流文档

本文档详细说明 Emora iOS 应用的权限设置、数据采集、编码、传输和接收逻辑。

---

## 1. 权限设置

### 1.1 权限类型与请求

应用需要两种系统权限：

| 权限类型 | 用途 | 状态键 |
|----------|------|--------|
| Camera | 视频采集 | `AVCaptureDevice.authorizationStatus(for: .video)` |
| Microphone | 音频采集 | `AVCaptureDevice.authorizationStatus(for: .audio)` |

```swift
// EmoraViewModel.swift 第57-83行
func checkPermissions() async -> Bool {
    let cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
    let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)

    var cameraGranted = cameraStatus == .authorized
    var micGranted = micStatus == .authorized

    // 首次请求时系统弹窗
    if cameraStatus == .notDetermined {
        cameraGranted = await AVCaptureDevice.requestAccess(for: .video)
    }
    if micStatus == .notDetermined {
        micGranted = await AVCaptureDevice.requestAccess(for: .audio)
    }

    return cameraGranted && micGranted
}
```

### 1.2 权限不足处理

- 权限被拒绝时弹出 Alert，引导用户前往 Settings 开启
- 音频 Session 配置 (`AudioCaptureManager.swift` 第43-47行):

```swift
try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetooth])
```

---

## 2. 数据来源与采集

### 2.1 视频数据来源

| 属性 | 值 | 说明 |
|------|-----|------|
| 来源设备 | `AVCaptureDevice` | 前置/后置摄像头 |
| 采集方式 | `AVCaptureSession` + `AVCaptureVideoDataOutput` | iOS 原生采集框架 |
| 像素格式 | `kCVPixelFormatType_32BGRA` | 32位 BGRA 格式 |
| 分辨率 | 1280x720 | 可通过 AppConfig.Video 修改 |
| 帧率 | 15 FPS | 可通过 AppConfig.Video.fps 修改 |
| 采集队列 | `encoderQueue` | 专用串行队列，避免阻塞主线程 |

**采集流程** (`VideoCaptureManager.swift` 第108-147行):

```swift
func setupSession() throws {
    let session = AVCaptureSession()
    session.sessionPreset = .high

    // 获取摄像头设备
    guard let camera = getCamera(for: currentCamera) else {
        throw VideoError.cameraNotAvailable
    }

    // 配置输入
    let input = AVCaptureDeviceInput(device: camera)
    guard session.canAddInput(input) else {
        throw VideoError.cannotAddInput
    }
    session.addInput(input)

    // 配置输出
    let output = AVCaptureVideoDataOutput()
    output.videoSettings = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ]
    output.setSampleBufferDelegate(self, queue: encoderQueue)
    output.alwaysDiscardsLateVideoFrames = true  // 丢弃过期帧

    session.addOutput(output)
}
```

### 2.2 音频数据来源

| 属性 | 值 | 说明 |
|------|-----|------|
| 来源设备 | `AVAudioEngine.inputNode` | 麦克风 |
| 采样率 | 24000 Hz | AppConfig.Audio.sampleRate |
| 声道数 | 1 | 单声道 AppConfig.Audio.channels |
| 采样格式 | PCM Int16 | 有符号 16 位整数 |
| 块大小 | 512 samples | AppConfig.Audio.chunkSize |

**采集流程** (`AudioCaptureManager.swift` 第42-73行):

```swift
func setupSession() throws {
    let session = AVAudioSession.sharedInstance()
    try session.setPreferredSampleRate(24000)
    try session.setPreferredIOBufferDuration(512.0 / 24000.0)

    audioEngine = AVAudioEngine()
    inputNode = engine.inputNode

    // 安装音频处理 tap
    let format = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: inputFormat.sampleRate,
        channels: AVAudioChannelCount(1),
        interleaved: true
    )!

    inputNode.installTap(onBus: 0, bufferSize: 512, format: format) { buffer, time in
        self.processAudioBuffer(buffer)  // 处理原始 PCM 数据
    }
}
```

---

## 3. 数据编码

### 3.1 视频编码 (H.264)

**编码器**: Apple VideoToolbox (`VTCompressionSession`)

**编码参数** (`VideoCaptureManager.swift` 第290-296行):

| 参数 | 值 | 说明 |
|------|-----|------|
| 编码器 | VideoToolbox | 硬件加速 H.264 编码 |
| Profile | Baseline | H.264 Baseline Auto Level |
| 比特率 | 1 Mbps | AppConfig.Video.bitrate |
| 关键帧间隔 | 30 帧 | 每 2 秒 (15fps × 2) 生成 IDR 帧 |
| 实时编码 | true | 实时编码模式 |
| Frame Reordering | false | 禁用 B 帧，降低延迟 |

```swift
let encoderSpecification: [String: Any] = [
    kVTCompressionPropertyKey_RealTime as String: kCFBooleanTrue!,
    kVTCompressionPropertyKey_ProfileLevel as String: kVTProfileLevel_H264_Baseline_AutoLevel,
    kVTCompressionPropertyKey_AverageBitRate as String: 1000000,
    kVTCompressionPropertyKey_MaxKeyFrameInterval as String: videoFPS * 2,
    kVTCompressionPropertyKey_AllowFrameReordering as String: kCFBooleanFalse!
]
```

**编码结果示例** (一帧 H.264 数据):

| 指标 | 典型值 |
|------|--------|
| 输入 (1280×720 BGRA) | ~622 KB |
| 输出 (H.264 帧) | 8-15 KB |
| 压缩比 | ~40:1 |

**关键帧 (IDR)**: 每 30 帧强制生成一个 IDR 帧，确保解码器可以独立解码。

### 3.2 音频编码 (AAC-LC)

**编码器**: Apple AudioToolbox (`AudioConverterRef`)

**编码参数** (`AudioCaptureManager.swift` 第120-168行):

| 参数 | 值 | 说明 |
|------|-----|------|
| 编码器 | AudioConverter | 软件 AAC 编码 |
| 格式 | MPEG-4 AAC | AppConfig.Audio |
| 采样率 | 24000 Hz | 与采集一致 |
| 帧/包 | 1024 samples | AAC 标准帧长 |
| 比特率 | 64 kbps | AppConfig.Audio.bitrate |
| 声道数 | 1 | 单声道 |

```swift
var outputFormat = AudioStreamBasicDescription(
    mSampleRate: 24000,
    mFormatID: kAudioFormatMPEG4AAC,
    mFormatFlags: 0,
    mBytesPerPacket: 0,
    mFramesPerPacket: 1024,  // AAC 必须以 1024 frame 为单位
    mBytesPerFrame: 0,
    mChannelsPerFrame: 1,
    mBitsPerChannel: 0,
    mReserved: 0
)

// 设置比特率
var bitRate: UInt32 = 64000
AudioConverterSetProperty(conv, kAudioConverterEncodeBitRate, &bitRate)
```

**编码结果示例** (一块 AAC 数据):

| 指标 | 典型值 |
|------|--------|
| 输入 (512 samples PCM Int16) | 1 KB |
| 输出 (AAC) | 40-80 bytes |
| 压缩比 | ~15:1 |

---

## 4. 数据发送

### 4.1 发送触发条件

| 数据类型 | 触发条件 | 触发位置 |
|----------|----------|----------|
| **连接** | 用户点击 Connect 按钮 | `EmoraViewModel.connect()` |
| **开始 Streaming** | `connectionState == .appReady` | `EmoraViewModel.startStreaming()` |
| **视频帧** | 每采集到一帧 BGRA 图像 → 编码完成 | `VideoCaptureManager.processEncodedFrame()` |
| **音频块** | 每采集到 512 samples → 编码完成 | `AudioCaptureManager.processAudioBuffer()` |
| **Vital** | 定时器每 2 秒 | `EmoraViewModel.handleVitalTimer()` |
| **Text** | 用户点击 "Send S" 按钮 | `EmoraViewModel.sendAnalysisRequest()` |

### 4.2 发送队列管理 (Backpressure)

**队列配置** (`AppConfig.swift`):

```swift
struct Queue {
    static let maxVideoQueueSize = 30      // ~2 seconds at 15fps
    static let maxAudioQueueSize = 100     // ~200ms at 512 samples
    static let maxVitalQueueSize = 5       // ~10 seconds at 2s interval
    static let sendIntervalMs = 16         // ~60fps max send rate
    static let dropAudioWhenFull = true
}
```

**丢弃策略**:
- **视频队列满**: 丢弃最旧的帧 (Ring Buffer 策略)
- **音频队列满**: 丢弃新的音频块
- **vital 队列满**: 丢弃新的 vital 数据

### 4.3 发送数据格式 (Payload JSON)

#### a) Text 消息 (点击 Send S 时)

```json
{
    "message_type": "text",
    "payload": {
        "user_id": "11",
        "messages": [
            {"role": "user", "content": "你好，这是本地多模态情绪分析测试。"}
        ],
        "prep_data": {
            "user_prompt": {
                "scene": "交谈场景",
                "intention": "请综合语音、表情和生命体征，判断用户当前压力与情绪状态。",
                "analysis": "输出结构化结果，包含情绪标签、强度，以及是否需要干预的建议。"
            }
        },
        "snapshot_window_sec": 15.0,
        "is_last": false,
        "request_id": "550E8400-E29B-41D4-A716-446655440000"
    }
}
```

#### b) Video 消息 (持续发送)

```json
{
    "message_type": "video",
    "payload": "{\"timestamp\":\"2026-03-10T10:30:00Z\",\"frame_index\":150,\"codec\":\"H264\",\"width\":1280,\"height\":720,\"data\":\"AAAAHGZ0d...base64编码的H264数据...\",\"size\":12345}"
}
```

**解码后的 payload 内容**:
```json
{
    "timestamp": "2026-03-10T10:30:00Z",
    "frame_index": 150,
    "codec": "H264",
    "width": 1280,
    "height": 720,
    "data": "<base64编码的H264数据>",
    "size": 12345
}
```

#### c) Audio 消息 (持续发送)

```json
{
    "message_type": "audio",
    "payload": "{\"timestamp\":\"2026-03-10T10:30:00Z\",\"chunk_index\":500,\"codec\":\"AAC\",\"sample_rate\":24000,\"channels\":1,\"data\":\"aNyD4ABt...base64编码的AAC数据...\",\"size\":64}"
}
```

**解码后的 payload 内容**:
```json
{
    "timestamp": "2026-03-10T10:30:00Z",
    "chunk_index": 500,
    "codec": "AAC",
    "sample_rate": 24000,
    "channels": 1,
    "data": "<base64编码的AAC数据>",
    "size": 64
}
```

#### d) Vital 消息 (每2秒发送)

```json
{
    "message_type": "vital",
    "payload": "{\"timestamp\":\"2026-03-10T10:30:00Z\",\"heart_rate\":75.5,\"breath_rate\":16.2,\"breath_amp\":0.75,\"conf\":0.92,\"init_stat\":1,\"presence_status\":1}"
}
```

**解码后的 payload 内容**:
```json
{
    "timestamp": "2026-03-10T10:30:00Z",
    "heart_rate": 75.5,
    "breath_rate": 16.2,
    "breath_amp": 0.75,
    "conf": 0.92,
    "init_stat": 1,
    "presence_status": 1
}
```

### 4.4 发送数据类型总览

| 字段 | 类型 | 说明 |
|------|------|------|
| `message_type` | String | 消息类型: text / video / audio / vital |
| `payload` | String (base64) / Object | 实际数据，video/audio 为 base64 编码 |

---

## 5. 数据接收

### 5.1 接收消息处理流程

```swift
// WebSocketManager.swift 第459-486行
func receiveMessage() {
    webSocketTask?.receive { result in
        handleReceiveResult(result)
    }
}

func handleReceiveResult(_ result: Result<URLSessionWebSocketTask.Message, Error>) {
    case .success(let message):
        handleTextMessage(text)  // JSON 字符串
    case .failure(let error):
        handleDisconnection(error: error)
}
```

### 5.2 接收消息解析

```swift
// WebSocketManager.swift 第492-562行
func handleTextMessage(_ string: String) {
    // 1. 解析 JSON
    let json = JSONSerialization.jsonObject(with: data) as? [String: Any]

    // 2. 获取消息类型
    let messageType = json["message_type"] as? String

    // 3. 根据类型处理
    switch messageType {
    case "ack":
        // 连接确认，状态切换到 appReady
    case "chunk":
        // 流式响应片段
    case "final":
        // 响应完成
    case "error":
        // 服务器错误
    }

    // 4. 存储到 responses 数组供 UI 显示
    responses.append(string)
}
```

### 5.3 接收消息类型

| message_type | 说明 |
|--------------|------|
| `ack` | WebSocket 连接建立成功，应用层已就绪 |
| `chunk` | 流式响应片段 (LLM 返回的文本/情绪分析结果) |
| `final` | 流式响应完成 |
| `error` | 服务器错误 (如 invalid_payload) |

---

## 6. 崩溃可能原因与解决方案

### 6.1 常见崩溃

| 原因 | 位置 | 解决方案 |
|------|------|----------|
| 摄像头被占用 | VideoCaptureManager | 添加 `isCapturing` 状态检查 |
| 音频 session 冲突 | AudioCaptureManager | 正确处理 interruption |
| JSON 序列化失败 | serializeToJSON | 过滤不支持的类型 (已修复) |
| WebSocket 断开 | receiveMessage | 重连逻辑 |
| 内存溢出 | 队列管理 | 限制队列大小 (已实现) |
| 前后台切换冲突 | VideoCaptureManager | 延迟重启 + 状态检查 |

### 6.2 特定错误码

```
-17281 (FigCapture): 摄像头捕获失败
  - 原因: App 进入后台后返回，前景冲突
  - 解决: 停止捕获 → 延迟 0.5s → 重新开始

Gesture timeout: 系统手势门控超时
  - 原因: UI 线程被阻塞
  - 解决: 减少主线程工作量
```

---

## 7. 发送频率与大小限制

### 7.1 频率限制

| 数据类型 | 频率 | 间隔 | 说明 |
|----------|------|------|------|
| 视频帧 | 15 fps | 66ms | 每帧 |
| 音频块 | ~46.875 Hz | 21.3ms | 24000/512 ≈ 46.9 次/秒 |
| Vital | 0.5 Hz | 2s | 定时器触发 |
| Heartbeat | 0.033 Hz | 30s | WebSocket 保活 |

### 7.2 大小限制

| 类型 | 配置值 | 说明 |
|------|-------|------|
| 视频比特率 | 1 Mbps | H.264 Baseline |
| 音频比特率 | 64 kbps | AAC-LC |
| 单帧视频 | ~15 KB | 典型 IDR 帧 |
| 单块音频 | ~64 bytes | AAC 1024 samples |
| 视频队列缓冲 | 30 帧 | ~450 KB |
| 音频队列缓冲 | 100 块 | ~6.4 KB |
| vital 队列缓冲 | 5 条 | ~500 bytes |

---

## 8. 后端推测

基于代码分析，推测后端服务结构：

### 8.1 连接信息

```
WebSocket URL: wss://api.finnox.cn/gateway/v1/proxy/ws
认证方式: Bearer Token (OAuth2)
```

### 8.2 接收能力

| 数据类型 | 格式要求 |
|----------|----------|
| text | JSON 对象 (user_id, messages, prep_data, snapshot_window_sec, is_last, request_id) |
| video | H.264 裸流，需要前端提取 SPS/PPS，base64 编码 |
| audio | AAC 裸流，base64 编码 |
| vital | JSON 对象 (heart_rate, breath_rate, breath_amp, conf, init_stat, presence_status) |

### 8.3 响应能力

| message_type | 说明 |
|--------------|------|
| ack | 连接确认 |
| chunk | 流式文本响应 (可能是 emotion analysis 结果) |
| final | 响应完成 |
| error | 错误信息 |

### 8.4 功能推测

1. **多模态情绪分析**: 接收视频 + 音频 + vital，综合分析用户情绪状态
2. **实时流处理**: 支持视频/音频流式输入
3. **上下文窗口**: `snapshot_window_sec=15` 秒
4. **干预建议**: prep_data 中包含 analysis 字段，请求结构化输出

### 8.5 当前问题排查

```
invalid_payload 错误可能原因:
1. payload 字段格式不匹配 (后端期望字段不同)
2. 字段类型错误 (如 number vs string)
3. 缺少必要字段
4. codec 名称不匹配 (如 "H264" vs "h264")
```

---

## 9. 架构流程图

```
┌─────────────────────────────────────────────────────────────────┐
│                         iOS 设备                                │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  ┌──────────────┐    ┌──────────────┐    ┌─────────────────┐   │
│  │   摄像头      │───►│ VideoCapture │───►│ H.264 编码      │   │
│  │ AVCapture    │    │   Manager    │    │ VTCompression  │   │
│  │   Session    │    │              │    │ Session         │   │
│  └──────────────┘    └──────────────┘    └────────┬────────┘   │
│                                                    │             │
│                                                    ▼             │
│  ┌──────────────┐    ┌──────────────┐    ┌─────────────────┐   │
│  │   麦克风      │───►│  AudioCapture│───►│ AAC 编码        │   │
│  │ AVAudioEngine│    │   Manager    │    │ AudioConverter  │   │
│  └──────────────┘    └──────────────┘    └────────┬────────┘   │
│                                                    │             │
│                                                    ▼             │
│                                           ┌─────────────────┐    │
│                                           │ Base64 编码     │    │
│                                           └────────┬────────┘    │
│                                                    │             │
│                                                    ▼             │
│                                           ┌─────────────────┐    │
│                                           │ WebSocketManager│    │
│                                           │  - 队列管理     │    │
│                                           │  - JSON 序列化  │    │
│                                           └────────┬────────┘    │
│                                                    │             │
│  ┌──────────────┐                                  │             │
│  │ Vital 定时器 │──────────────────────────────────┘             │
│  │  (每 2 秒)   │                                              │
│  └──────────────┘                                              │
│                                                                  │
└──────────────────────────────┬───────────────────────────────────┘
                               │
                               ▼
┌──────────────────────────────────────────────────────────────────┐
│                      后端服务器                                    │
│  wss://api.finnox.cn/gateway/v1/proxy/ws                        │
│                                                                  │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │  1. 验证 Token (Bearer Auth)                               │  │
│  │  2. 接收 video/audio/vital 流                             │  │
│  │  3. 多模态情绪分析                                         │  │
│  │  4. 返回 chunk/final 响应                                 │  │
│  └────────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────┘
```

---

## 10. 关键文件索引

| 文件 | 职责 |
|------|------|
| `EmoraViewModel.swift` | 业务逻辑、状态管理、权限处理、Combine 绑定 |
| `WebSocketManager.swift` | WebSocket 连接、消息发送/接收、队列管理 |
| `VideoCaptureManager.swift` | 视频采集、H.264 编码、SPS/PPS 提取 |
| `AudioCaptureManager.swift` | 音频采集、AAC 编码 |
| `StreamQueueManager.swift` | 背压队列 (Ring Buffer) 实现 |
| `AppConfig.swift` | 配置常量 (URL、Token、队列大小、视频/音频参数) |
| `ResponsePanel.swift` | 历史消息显示 UI |
| `ControlPanel.swift` | 连接/断开/发送控制 UI |

---

## 11. 版本信息

| 项目 | 值 |
|------|-----|
| 文档版本 | 1.0 |
| 创建日期 | 2026-03-10 |
| iOS 目标版本 | iOS 15.0+ |
| 框架 | SwiftUI + Combine |
