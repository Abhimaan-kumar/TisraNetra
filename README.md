# Tisra Netra

Tisra Netra is a Flutter accessibility app for blind and visually impaired users. It combines English and Hindi voice interaction, hardware volume-button controls, camera assistance, walking directions, and volunteer video calls. Earlier files may refer to the app as LifeLens or Percive.

## Documentation

- [Volume button controls and voice commands](VOLUME_BUTTON_GUIDE.md)
- [Architecture overview](ARCHITECTURE.md)
- [Architecture and Project report.md](Architecture%20and%20Project%20report.md)
- [Sample data and manual test cases](samples/README.md)

## Features and platform support

| Feature | Implementation | Network requirement |
| --- | --- | --- |
| Read Anything | ML Kit OCR for English and Hindi | On-device recognition |
| Currency and color detection | OCR of rupee denominations; camera color sampling | On-device processing |
| Person identification | MobileFaceNet embeddings stored in SQLite | On-device recognition |
| Navigation | GPS directions, SSD MobileNet detection, MiDaS depth estimation, and path analysis | Routes require Google Maps; camera processing is local |
| Object recognition and scene captioning | Camera processing with Gemini-assisted descriptions | Cloud descriptions require Gemini |
| AI Buddy | Gemini conversational assistance | Internet and a Gemini key |
| Volunteer assistance | Firebase help requests, FCM, and WebRTC audio/video | Internet and configured Firebase services |

**Android is the currently configured target.** Firebase initialization throws an unsupported-platform error on the other platforms. Platform directories alone do not mean those targets are ready to run. Speech recognition also depends on the device's speech service.

## Setup

### 1. Install prerequisites

- Flutter with Dart **3.10.1 or a compatible newer 3.x version**, as required by [pubspec.yaml](pubspec.yaml).
- Android SDK tools and a Java 17-compatible toolchain; check them with `flutter doctor -v`.
- Android **8.0 / API 26 or newer**. A physical device is recommended for camera, GPS, volume buttons, and calls; use a Google Play-enabled emulator for messaging.
- Firebase project access, Gemini credentials, and access to Google Maps Directions API (Legacy).
- Node.js **22** and npm when setting up the Firebase function in [functions/](functions/).

### 2. Clone and install dependencies

```sh
git clone https://github.com/Abhimaan-kumar/TisraNetra.git
cd TisraNetra
flutter doctor -v
flutter pub get
```

The models are checked in under [assets/models/](assets/models/): `mobile_face_net.tflite`, `ssd_mobilenet_v2.tflite`, `midas_v2_small.tflite`, and `coco_labels.txt`. Keep these files in place; `pubspec.yaml` declares their asset paths. The MiDaS model makes the initial clone comparatively large.

### 3. Create your local `.env`

Copy [.env.example](.env.example) to `.env` in the project root. **Keep an existing `.env` if you already have one.**

PowerShell:

```powershell
Copy-Item .env.example .env
```

macOS/Linux:

```sh
cp .env.example .env
```

Fill in the variables described below. Use plain `NAME=value` entries without wrapping quotes because the Android Gradle reader uses Java properties. `.env` and local `.env.*` files are ignored; only the blank `.env.example` is tracked.

### 4. Configure Firebase

The checked-in project identifiers refer to `tisra-netra`. If you already have access to that project, add its Firebase API key to `FIREBASE_API_KEY` in `.env` and keep the supplied identifiers/template.

For your own project, follow the [official FlutterFire setup guide](https://firebase.google.com/docs/flutter/setup):

```sh
npm install -g firebase-tools
firebase login
dart pub global activate flutterfire_cli
flutterfire configure
firebase use --add
dart run tool/import_firebase_config.dart
```

Select your project and **Android** during configuration. Run the importer immediately afterward: it moves the generated Firebase key to your local `.env`, replaces the Dart literal with `String.fromEnvironment('FIREBASE_API_KEY')`, and creates a key-free [google-services.json.template](android/app/google-services.json.template). It preserves other `.env` variables and updates an existing `FIREBASE_API_KEY` when switching projects. Repeat the import whenever FlutterFire regenerates the configuration.

Android Gradle creates the ignored `android/app/google-services.json` from that template and `.env` during each build configuration. Do not commit the generated JSON. Confirm that [lib/firebase_options.dart](lib/firebase_options.dart), the template, and [.firebaserc](.firebaserc) refer to the same project. The Android application ID is `com.futureluck.tisranetrta`.

In the Firebase console, enable **Authentication → Email/Password** and create a **Cloud Firestore** database. Registration creates `users/{uid}` documents with the selected `Client` or `Volunteer` role; no database seed is required.

Review [firestore.rules](firestore.rules) before deploying. They currently allow any signed-in user to read/write every document and need tighter rules for a production deployment.

### 5. Run on Android

```sh
flutter devices
flutter run --dart-define-from-file=.env
```

Add `-d DEVICE_ID` when multiple devices are connected. Allow camera, microphone, location, and notification permissions when prompted. Select English or Hindi in registration/profile. On the home screen, press **Volume Up** and say a feature name such as "read", "navigate", or "ai buddy". See the [volume button guide](VOLUME_BUTTON_GUIDE.md) for feature-specific controls.

### 6. Set up volunteer notifications (optional)

`notifyVolunteersOnHelpRequest` sends notifications to users whose role is `Volunteer` when a help request is created. Install and deploy to your intended Firebase project:

```sh
cd functions
npm ci
npm run lint
cd ..
firebase deploy --only firestore:rules,functions
```

Functions deployment requires the **Blaze** plan; see the [official functions setup guide](https://firebase.google.com/docs/functions/get-started). These commands deploy backend code and rules. Check calls with two signed-in Android devices, one `Client` and one `Volunteer`.

## Environment variables

| Variable | Required for | Behavior |
| --- | --- | --- |
| `FIREBASE_API_KEY` | Firebase initialization and Android builds | Dart reads a compile-time define; Gradle fills the generated local Firebase JSON from `.env`. Must match your Firebase project. |
| `GEMINI_API_KEY` | AI Buddy; default key for cloud vision | Read through Dart's `String.fromEnvironment` at build time. |
| `GEMINI_VISION_API_KEY` | Optional separate vision key | Object recognition/scene captioning fall back to `GEMINI_API_KEY` when omitted. |
| `GOOGLE_MAPS_API_KEY` | Walking route requests | Used by the Directions API (Legacy) client; also the Android manifest fallback. |
| `GOOGLE_MAPS_ANDROID_API_KEY` | Optional separate Android Maps key | Gradle reads it from `.env`; falls back to `GOOGLE_MAPS_API_KEY` when omitted. |
| `TURN_URLS` | Optional WebRTC relay | Comma-separated TURN URLs, for example `turn:your-relay.example:3478`. |
| `TURN_USERNAME` | WebRTC relay authentication | Relay username; used only with nonempty `TURN_URLS` and `TURN_PASSWORD`. |
| `TURN_PASSWORD` | WebRTC relay authentication | Relay credential. Without all three TURN values, calls use the configured public STUN servers only. |
| `BACKED_URL` | Nothing in the current app | Retained for compatibility; no current source reads it. The spelling is intentional. |

Leave optional fallback variables **out of `.env`** to use their defaults; setting them to empty overrides the fallback with an empty key. Include `--dart-define-from-file=.env` for runs/builds, and restart/rebuild after changing values. The local `.env` retains any existing keys and relay settings migrated from previous code.

Create a Gemini key through [Google AI Studio](https://aistudio.google.com/). Check access to the models named in source: AI Buddy requests `gemini-3-flash-preview`; vision services request `gemini-2.5-flash` / `gemini-2.5-flash-lite`. Model names are source settings, not environment variables.

Navigation calls **Directions API (Legacy)**. Its project needs billing and access to that API; enabling the newer Routes API alone does not configure this client. See [Google's Directions key setup](https://developers.google.com/maps/documentation/directions/get-api-key). Use restrictions appropriate to each key's use; an Android SDK-restricted key may not authorize a Directions HTTP request.

Keeping keys in `.env` prevents new repository exposure; client build values can still be present in the compiled app. Use appropriate key restrictions and a backend for credentials that must remain server-side. Removing a key from current source does not remove it from previously published commits.

## Build an APK

For a development APK:

```sh
flutter build apk --debug --dart-define-from-file=.env
```

For a signed release, configure your own ignored `android/key.properties`:

```properties
storeFile=/absolute/path/to/your-release-key.jks
storePassword=YOUR_STORE_PASSWORD
keyAlias=YOUR_KEY_ALIAS
keyPassword=YOUR_KEY_PASSWORD
```

Then run:

```sh
flutter build apk --release --dart-define-from-file=.env
```

APKs are written under `build/app/outputs/flutter-apk/`. The release configuration expects those signing properties. Keep passwords and the keystore out of Git.

## Sample data and tests

[samples/README.md](samples/README.md) provides a manual device checklist, bilingual OCR text, a color target, and synthetic navigation data. They are test materials, not app assets or a Firestore seed. Camera features require displaying/printing the samples and capturing them on a device.

Run the automated suite from the repository root:

```sh
flutter test
```

Or run the added cases directly:

```sh
flutter test test/navigation_step_test.dart test/volume_button_service_test.dart test/firebase_config_import_test.dart
```

These tests check spoken navigation cues, missing/unknown maneuvers, volume-event routing/restoration, and key-free Firebase imports that preserve other environment values. They make no cloud requests and do not use your private `.env`. The existing `test/widget_test.dart` checks only the test framework; `tflite_test.dart` is a native-model diagnostic outside the default test directory.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| Missing Firebase key / Firebase initialization error | Set `FIREBASE_API_KEY`, pass the environment-file flag, and check that the project identifiers match it. |
| FlutterFire reintroduced a key literal | Run `dart run tool/import_firebase_config.dart` before committing generated changes. |
| Gemini authentication/model error | Check the appropriate key and access to the model named in source. |
| Directions request denied | Check Directions API (Legacy) access, billing, and key restrictions. |
| Firebase permission or sign-in error | Check Email/Password sign-in and deployed Firestore rules. |
| No volunteer notification | Check the function deployment, exact `Volunteer` role, saved FCM token, and notification permission. |
| Calls fail on some networks | Configure working TURN URLs and matching relay credentials; STUN alone may not traverse every network. |
| Camera, voice, or location unavailable | Check Android permissions and device services; retry on a physical device. |
| Release signing failure | Check `android/key.properties` and the keystore path. |
| Unsupported platform | Run on Android; other targets require Firebase and native-plugin configuration. |

## License

See [LICENSE](LICENSE).
