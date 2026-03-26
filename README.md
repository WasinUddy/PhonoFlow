# PhonoFlow

A professional menu bar app for monitoring and streaming audio from your turntable on macOS.

## Features

- **Audio Monitoring**: Real-time passthrough with adjustable gain
- **Radio Streaming**: HTTP audio streaming server for network playback
- **Waveform Meter**: LED-style 48-segment meter with color-coded levels
- **Basic/Pro Modes**: Simplified or advanced interface
- **Theme Support**: 5 beautiful color themes
- **Low CPU Usage**: Optimized Core Audio implementation (~2-5% CPU)
- **Launch at Login**: Auto-start option

## System Requirements

- macOS 14.0 (Sonoma) or later
- Apple Silicon or Intel Mac
- Microphone permission (automatically requested)

## Installation

1. Download `PhonoFlow.dmg` from [Releases](../../releases)
2. Open the DMG and drag PhonoFlow to Applications
3. **First Launch**: Right-click PhonoFlow.app → Open (to bypass Gatekeeper)
4. Or run in Terminal: `xattr -cr /Applications/PhonoFlow.app`

## Usage

### Basic Mode
- Select input/output devices
- Click "Monitor" to enable audio passthrough
- Adjust gain with the slider

### Pro Mode
- All Basic mode features
- Live waveform meter with dB scale
- Radio streaming server
- Status indicators
- Stream URL with one-click copy

## Settings

Access via the gear icon in the menu bar:

- **General**: Toggle Basic/Pro mode, Launch at Login
- **Radio**: Configure streaming port and allowed hosts
- **Appearance**: Choose from 5 color themes

## Building from Source

```bash
git clone <repository-url>
cd PhonoFlow
open PhonoFlow.xcodeproj
```

Build in Xcode or use GitHub Actions to build DMG artifacts.

## License

All rights reserved.
