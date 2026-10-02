# Tisra Netra

A voice controlled multi platform application for visually challenged person (formerly LifeLens)


## Help

- [Lab: Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Cookbook: Useful Flutter samples](https://docs.flutter.dev/cookbook)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.

## Local configuration

Copy `.env.example` to `.env` and fill in your Gemini and Google Maps API keys.
The `.env` file is private and ignored by Git.

Run the app with:

```sh
flutter run --dart-define-from-file=.env
```

Use the same option for release builds, for example:

```sh
flutter build apk --dart-define-from-file=.env
```
