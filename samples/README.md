# Sample data and manual test cases

These synthetic materials are for development checks. They are not automatically imported into the app, uploaded to Firebase, or bundled as assets.

## Samples

| File | Use | Expected observation |
| --- | --- | --- |
| [ocr_english.txt](ocr_english.txt) | Display/print in a large, clear font; scan with Read Anything. | Recognize the heading, opening time, and room number, then speak the text. |
| [ocr_hindi.txt](ocr_hindi.txt) | Display/print with a Devanagari-capable font; scan with Read Anything. | Recognize and speak the Hindi text. |
| [color_targets.svg](color_targets.svg) | Open in a browser; aim at the center of each block. | Identify red, green, and blue; lighting/display conditions can affect estimates. |
| [navigation_steps.json](navigation_steps.json) | Fixture for the navigation unit tests. | Clock-position cues for known maneuvers; `continue` for missing/unknown maneuvers. |

The navigation fixture uses fictional coordinates near `(0, 0)` and is not a real route or full Google API response. Compare recognized content rather than exact OCR punctuation or an exact AI-generated sentence.

## Device checklist

Record the Android/device version, commit, language, permissions, steps, expected/actual results, and pass/fail. Use your own development Firebase project for account/call checks.

| ID | Setup | Action | Expected result |
| --- | --- | --- | --- |
| M01 | Home; microphone enabled | Press Volume Up and say "read". | Read Anything opens; Volume Down returns to the previous screen. |
| M02 | Home; microphone enabled | Start listening, then press Volume Up again. | Listening cancels without opening a feature. |
| M03 | English OCR sample | Scan the displayed/printed text, then repeat. | Heading, `9:00 AM`, and `Room 12` are recognized; repeat speaks the last result. |
| M04 | Hindi OCR sample; Hindi preference | Scan the text. | Devanagari text is recognized and spoken. |
| M05 | Read Anything; blank sheet | Scan the blank sheet. | No readable text is reported, rather than treating an old result as a new scan. |
| M06 | Color target; steady lighting | Fill the camera center with each block. | Detected color changes between red, green, and blue. |
| M07 | Visible cup/chair; vision key | Scan and repeat in Object Recognition. | Relevant label/description; repeat reuses the last result. |
| M08 | Simple indoor scene; vision key/network | Scan in scene captioning. | A description related to the scene is produced. |
| M09 | AI Buddy; Gemini key | Ask "What can you help me with?" | A spoken conversational response. |
| M10 | Navigation; GPS/camera permissions; Directions key | Choose a nearby walking destination in a controlled test area. | Route requested, spoken guidance, and GPS progress updates. |
| M11 | Person identification; consenting tester | Enroll a face, leave the screen, then rescan. | The saved name can be recognized from local storage. |
| M12 | Development Firebase; two devices | Register `Client` and `Volunteer`, allow notifications, then request help. | Pending request and a volunteer notification when the function/token are configured. |
| M13 | Pending help request | Press Volume Down before acceptance. | Request becomes `cancelled`; client exits the pending state. |
| M14 | Accepted request; permissions on both devices | Connect, verify audio/video, then end the call. | Media connects and the call terminates cleanly. |
| M15 | Home; microphone permission denied | Attempt a voice command. | Unavailable microphone/listening is reported instead of navigating on empty input. |

This is **not a record of completed device testing**. Camera accuracy, GPS, speech, Firebase, and WebRTC must be checked on devices.

## Automated checks

From the repository root:

```sh
flutter test test/navigation_step_test.dart test/volume_button_service_test.dart test/firebase_config_import_test.dart
```

Navigation tests consume the JSON fixture. Volume-button tests inject method-channel events and verify screen routing/restoration. Firebase import tests use temporary directories and fake keys to check sanitization and preservation of unrelated `.env` values. No test makes a cloud request or reads your private `.env`.
