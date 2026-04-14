# Volume Button Controls & Voice Commands - LifeLens App

## Overview

The LifeLens app now supports comprehensive volume button controls and voice commands throughout the entire application. This enables hands-free operation with full language support for both English and Hindi.

## Global Controls

### Home Screen
- **Volume Up Button**: Listen for voice commands to open features
  - Say feature name to open it (e.g., "read anything", "padho ye kya likha hai", "object recognition", etc.)
  - Supported commands:
    - "read" / "padho" → Read Anything
    - "currency" / "rupee" → Currency Detection
    - "navigate" / "direction" → Navigate
    - "object" / "recognize" → Object Recognition
    - "scene" / "caption" / "describe" → Scene Captioning
    - "person" / "identify" / "face" → Person Identification
    - "color" / "rang" → Color Detection
    - "talk" / "voluntary" / "help" → Talk with Volunteer
    - "ai" / "buddy" / "chat" → AI Buddy
    - "emergency" / "emergency help" → Emergency

- **Volume Down Button**: 
  - On home screen: Feedback "You are on home screen"
  - On feature screens: Go back to home screen

### Language Support
- **English (en-IN)**: Commands and responses in English with Indian accent
- **Hindi (hi-IN)**: Commands and responses in Hindi (Devanagari script)
- **Automatic Detection**: The app automatically detects the language of your voice input and responds in the same language

---

## Feature-Specific Controls

### 1. **Read Anything Screen**
**Purpose**: Read text from camera feed automatically

- **Volume Up Button**: 
  - Initiates voice listening to recognize commands
  - Supported commands:
    - "repeat" / "phir" / "padho" → Repeat the last text read
    - "scan" / "again" / "dubara scan kro" → Scan and read new text

- **Volume Down Button**: Go back to home screen

**Hindi Voice Commands**:
- "फिर से पढ़ो" (Phir se padho) - Repeat reading
- "दोबारा स्कैन करो" (Doubara scan kro) - Scan again
- "होम पर वापस" (Home par waapis) - Go back to home

---

### 2. **Scene Captioning Screen**
**Purpose**: Describe the scene in front of the camera

- **Volume Up Button**: 
  - Voice listening for commands
  - Supported commands:
    - "repeat" / "phir" / "padho" → Repeat scene description
    - "scan" / "again" / "dubara" → Scan scene again

- **Volume Down Button**: Go back to home screen

---

### 3. **Object Recognition Screen**
**Purpose**: Identify and describe objects

- **Volume Up Button**:
  - Voice listening for commands
  - Supported commands:
    - "repeat" / "phir" / "padho" → Repeat object identification
    - "scan" / "again" / "dubara scan kro" → Scan again

- **Volume Down Button**: Go back to home screen

---

### 4. **Color Detection Screen**
**Purpose**: Identify colors

- **Volume Up Button**:
  - Voice listening for commands
  - Supported commands:
    - "repeat" / "phir" / "padho" → Repeat color description
    - "scan" / "again" / "dubara" → Rescan

- **Volume Down Button**: Go back to home screen

---

### 5. **Person Identification Screen**
**Purpose**: Identify and recognize people

- **Volume Up Button**:
  - Voice listening for commands
  - Supported commands:
    - "repeat" / "phir" / "padho" → Repeat person identification
    - "scan" / "again" / "dubara scan kro" → Rescan

- **Volume Down Button**: Go back to home screen

---

### 6. **Currency Detection Screen**
**Purpose**: Detect and read currency

- **Volume Up Button**: 
  - Listen for commands and restart scanning
  - Supported commands:
    - "repeat" / "phir" / "padho" → Repeat currency identification
    - "scan" / "again" / "restart" / "dubara" → Scan again

- **Volume Down Button**: Go back to home screen

---

### 7. **AI Buddy Screen**
**Purpose**: Chat with AI assistant

- **Volume Up Button**: 
  - Start voice input to send message to AI
  - Speak your question/message, it will be sent automatically

- **Volume Down Button**: Go back to home screen

---

### 8. **Talk with Volunteer Screen**
**Purpose**: Request help from a human volunteer

- **Volume Up Button**: 
  - Call a volunteer (if no call is active)
  - Initiates help request

- **Volume Down Button**: 
  - Cancel the help request (if active) 
  - Go back to home (if no active request)

---

### 9. **Navigation Screen**
**Purpose**: Navigation assistance (coming soon)

- **Volume Up Button**: Get navigation help (feature under development)
- **Volume Down Button**: Go back to home screen

---

### 10. **Emergency Screen**
**Purpose**: Send emergency alert

- **Volume Up Button**: Send emergency alert to volunteers
- **Volume Down Button**: Go back to home screen

---

## Voice Command Examples

### English Examples
```
Home Screen:
"Open read anything"
"Open object recognition"
"Open color"

Feature Screens:
"Repeat"
"Scan again"
"Read again"
"Play again"
```

### Hindi Examples
```
होम स्क्रीन:
"पढ़ो कुछ भी खोलो" (Padho kuch bhi kholo - Open read anything)
"वस्तु पहचान खोलो" (Vastu pehchan kholo - Open object recognition)
"रंग खोलो" (Rang kholo - Open color)

फीचर स्क्रीन:
"फिर से पढ़ो" (Phir se padho - Repeat)
"दोबारा स्कैन करो" (Doubara scan kro - Scan again)
"दोबारा पढ़ो" (Doubara padho - Read again)
"फिर से बोलो" (Phir se bolo - Speak again)
```

---

## Technical Implementation

### Services Used

1. **VolumeButtonService** (`lib/services/volume_button_service.dart`)
   - Handles hardware volume button detection
   - Uses Android MethodChannel for native integration
   - Manages callback routing for volume up/down events

2. **VoiceCommandService** (`lib/services/voice_command_service.dart`)
   - Performs speech-to-text recognition
   - Automatically detects language (English/Hindi)
   - Supports dual language input

3. **TtsService** (`lib/services/tts_service.dart`)
   - Text-to-speech with language support
   - Responds in English or Hindi based on input language
   - Handles multi-language segments (e.g., mixed Hindi-English text)

4. **VolumeButtonMixin** (`lib/widgets/volume_button_mixin.dart`)
   - Reusable mixin for feature screens
   - Provides common volume button behavior
   - Simplifies implementation across screens

### Android Native Implementation

Ensure your Android `MainActivity.kt` has the MethodChannel handler:

```kotlin
private val volumeButtonChannel = "com.lifelens.app/volumebutton"

override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)
    
    MethodChannel(flutterEngine.dartExecutor.binaryMessenger, volumeButtonChannel)
        .setMethodCallHandler { call, result ->
            when (call.method) {
                "onVolumeUp" -> {
                    // Handle volume up
                    result.success(null)
                }
                "onVolumeDown" -> {
                    // Handle volume down
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
}
```

---

## Permissions Required

Ensure these permissions are in your `android/app/src/main/AndroidManifest.xml`:

```xml
<uses-permission android:name="android.permission.CAMERA" />
<uses-permission android:name="android.permission.RECORD_AUDIO" />
<uses-permission android:name="android.permission.INTERNET" />
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />
<uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION" />
```

---

## Tips for Users

1. **Always speak clearly** - Enunciate words properly for better recognition
2. **Keep commands short** - Single or two-word commands work best
3. **Wait for feedback** - Listen for TTS confirmation before speaking next command
4. **Check language settings** - Ensure your device language matches your speech input language
5. **Use distinctive commands** - Use clear, recognizable words to avoid misinterpretation

---

## Troubleshooting

### Volume buttons not working
- Check if MethodChannel is properly set up in Android code
- Ensure app has microphone permission
- Try restarting the app

### Voice commands not recognized
- Speak clearly and at normal volume
- Check internet connection for speech recognition API
- Ensure microphone is not blocked

### Wrong language response
- The app auto-detects based on your voice input
- If getting wrong language, try speaking with clearer accent of target language
- Manual language selection coming in future update

### TTS not playing
- Check device volume is not muted
- Ensure text-to-speech engine is installed on your device
- Try going to system settings → Language & input → Text-to-speech

---

## Future Enhancements

- [ ] Manual language selection option
- [ ] Custom voice command configuration
- [ ] Gesture-based controls
- [ ] Volume button shortcut customization per feature
- [ ] Multi-language support (more languages)
- [ ] Improved offline support for voice recognition

---

## Support

For issues or feature requests related to volume button controls, please create an issue in the repository or contact the development team.
