# Emora iOS App Specification

## 1. Project Overview

- **Project Name**: emora-ios
- **Bundle Identifier**: com.emora.ios
- **Core Functionality**: Real-time emotion analysis app using camera and microphone, communicating with backend via WebSocket
- **Target Users**: Users who want to analyze their emotional state
- **iOS Version**: iOS 17.0+
- **UI Framework**: SwiftUI

## 2. UI/UX Specification

### Screen Structure

Single main screen with:
- Full-screen camera preview
- Control overlay
- Response display panel

### Visual Design

**Color Palette**:
- Primary: `#6366F1` (Indigo)
- Secondary: `#8B5CF6` (Purple)
- Accent: `#EC4899` (Pink)
- Background: `#000000` (Black - for camera background)
- Surface: `#1F2937` (Dark gray)
- Text Primary: `#FFFFFF`
- Text Secondary: `#9CA3AF`
- Success: `#10B981` (Green)
- Error: `#EF4444` (Red)

**Typography**:
- Title: SF Pro Display Bold, 24pt
- Heading: SF Pro Display Semibold, 18pt
- Body: SF Pro Text Regular, 16pt
- Caption: SF Pro Text Regular, 14pt

**Spacing**:
- Base unit: 8pt
- Small: 8pt
- Medium: 16pt
- Large: 24pt
- XLarge: 32pt

### Views & Components

1. **CameraPreviewView**
   - Full-screen camera preview
   - Front/back camera toggle button (top-right)
   - Connection status indicator (top-left)

2. **ControlPanel**
   - Send Request Button ("s") - Primary action button
   - Connection status label
   - Switch camera button

3. **ResponsePanel**
   - Scrollable text display for backend responses
   - Clear button
   - Real-time streaming updates

### Interactive Behaviors

- Tap "s" button to send analysis request
- Tap camera switch to toggle front/back camera
- Auto-reconnect on connection loss
- Real-time response display with auto-scroll

## 3. Functionality Specification

### Core Features

1. **WebSocket Connection**
   - Connect to: `wss://api.finnox.cn/gateway/v1/proxy/ws?token=25942d659fd81c3a4faa8deae5d3e278.CwjYQzIEqF1uHX0f7EG9CiBfZN14qRimke4lixE9dzw`
   - Auto-reconnect on disconnect (max 5 retries, exponential backoff)
   - Send heartbeat every 30 seconds

2. **Video Capture**
   - Resolution: 640x360
   - Frame rate: 15 fps
   - Codec: H.264 (using VideoToolbox)
   - Switch between front/back camera

3. **Audio Capture**
   - Sample rate: 24000 Hz
   - Channels: 1 (mono)
   - Codec: AAC (using AudioToolbox)
   - Format: ADTS

4. **Data Transmission**
   - Send video frames in H.264 format (base64 encoded)
   - Send audio chunks in AAC format (base64 encoded)
   - Send text message when user taps "s" button
   - Message format matches client.py:
     ```json
     {"message_type": "text", "payload": {...}}
     {"message_type": "video", "payload": {...}}
     {"message_type": "audio", "payload": {...}}
     {"message_type": "vital", "payload": {...}}
     ```

5. **Response Handling**
   - Display streaming responses from server
   - Parse and display emotion analysis results
   - Show connection status

### User Interactions

1. **Launch** → Connect WebSocket → Start video/audio capture → Stream data
2. **Tap "s" Button** → Send text message → Receive response
3. **Tap Camera Switch** → Toggle front/back camera
4. **Connection Lost** → Auto-reconnect → Resume streaming

### Architecture

MVVM Architecture:
- **Models**: WebSocketMessage, EmotionResponse, MediaFrame
- **ViewModels**: EmoraViewModel (manages state and business logic)
- **Views**: ContentView, CameraPreviewView, ControlPanel, ResponsePanel

### Edge Cases & Error Handling

- Camera permission denied → Show settings prompt
- Microphone permission denied → Show settings prompt
- WebSocket disconnect → Auto-reconnect
- Network unavailable → Show offline indicator
- Encoding failure → Skip frame, continue

## 4. Technical Specification

### Dependencies (Swift Package Manager)

1. **Starscream** - WebSocket client (v4.0.6)
   - Repository: https://github.com/daltoniam/Starscream
   - Purpose: Stable WebSocket connection with reconnection support

### Required Frameworks

- AVFoundation - Camera and microphone capture
- VideoToolbox - H.264 hardware encoding
- AudioToolbox - AAC encoding
- Combine - Reactive programming

### Info.plist Permissions

```xml
NSCameraUsageDescription: "Emora needs camera access to analyze your emotions"
NSMicrophoneUsageDescription: "Emora needs microphone access to analyze your emotions"
```

### Asset Requirements

- App Icon (1024x1024)
- SF Symbols for UI icons:
  - camera.rotate
  - mic.fill
  - video.fill
  - paperplane.fill
  - wifi.slash
  - checkmark.circle.fill

## 5. Message Protocol (from client.py)

### Send Message Format
```json
{"message_type": "text", "payload": {...}}
{"message_type": "video", "payload": {...}}
{"message_type": "audio", "payload": {...}}
{"message_type": "vital", "payload": {...}}
```

### Video Payload
```json
{
  "timestamp": "2024-01-01T00:00:00.000Z",
  "frame_index": 0,
  "codec": "H264",
  "width": 640,
  "height": 360,
  "data": "<base64 encoded H264 data>",
  "size": 1234
}
```

### Audio Payload
```json
{
  "timestamp": "2024-01-01T00:00:00.000Z",
  "chunk_index": 0,
  "codec": "AAC",
  "sample_rate": 24000,
  "channels": 1,
  "data": "<base64 encoded AAC data>",
  "size": 1234
}
```

### Text Payload (for "s" request)
```json
{
  "user_id": "11",
  "messages": [{"role": "user", "content": "..."}],
  "prep_data": {...},
  "snapshot_window_sec": 15,
  "is_last": false
}
```

### Vital Payload (optional)
```json
{
  "timestamp": "2024-01-01T00:00:00.000Z",
  "heart_rate": 75.5,
  "breath_rate": 16.0,
  "breath_amp": 0.75,
  "conf": 0.9,
  "init_stat": 1,
  "presence_status": 1
}
```

### Receive Message Format
```json
{"message_type": "chunk", "payload": {...}, "seq": 0, "is_final": false}
```
