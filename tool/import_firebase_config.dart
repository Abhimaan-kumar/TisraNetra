import 'dart:convert';
import 'dart:io';

/// Imports Android-only FlutterFire output without leaving keys in tracked files.
void importFirebaseConfig(Directory root) {
  final jsonFile = File('${root.path}/android/app/google-services.json');
  final dartFile = File('${root.path}/lib/firebase_options.dart');
  final config =
      jsonDecode(jsonFile.readAsStringSync()) as Map<String, dynamic>;
  final clients = config['client'] as List<dynamic>;
  final keys = <String>{};
  for (final client in clients.cast<Map<String, dynamic>>()) {
    for (final apiKey
        in (client['api_key'] as List<dynamic>).cast<Map<String, dynamic>>()) {
      final key = apiKey['current_key'] as String;
      if (key.isNotEmpty) keys.add(key);
    }
  }
  if (keys.length != 1) {
    throw const FormatException(
      'Expected a single Android Firebase API key in FlutterFire output.',
    );
  }
  final key = keys.single;
  final source = dartFile.readAsStringSync();
  final apiKeyPattern = RegExp(r"apiKey:\s*'([^']*)'");
  final sourceKeys = apiKeyPattern.allMatches(source).toList();
  if (sourceKeys.isEmpty || sourceKeys.any((match) => match.group(1) != key)) {
    throw const FormatException(
      'Expected matching Android-only Firebase keys in both generated files. '
      'Run flutterfire configure for Android before importing.',
    );
  }
  final cleanSource = source.replaceAll(
    apiKeyPattern,
    "apiKey: String.fromEnvironment('FIREBASE_API_KEY')",
  );
  for (final client in clients.cast<Map<String, dynamic>>()) {
    for (final apiKey
        in (client['api_key'] as List<dynamic>).cast<Map<String, dynamic>>()) {
      apiKey['current_key'] = '';
    }
  }

  final envFile = File('${root.path}/.env');
  final originalEnv = envFile.existsSync() ? envFile.readAsStringSync() : '';
  final newline = originalEnv.contains('\r\n') ? '\r\n' : '\n';
  final envKeyPattern = RegExp(r'^FIREBASE_API_KEY=[^\r\n]*', multiLine: true);
  final String environment;
  if (envKeyPattern.hasMatch(originalEnv)) {
    environment = originalEnv.replaceAll(
      envKeyPattern,
      'FIREBASE_API_KEY=$key',
    );
  } else {
    final separator = originalEnv.isEmpty || originalEnv.endsWith('\n')
        ? ''
        : newline;
    environment = '$originalEnv${separator}FIREBASE_API_KEY=$key$newline';
  }

  envFile.writeAsStringSync(environment);
  dartFile.writeAsStringSync(cleanSource);
  File(
    '${root.path}/android/app/google-services.json.template',
  ).writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(config)}\n',
  );
}

void main() {
  try {
    importFirebaseConfig(Directory.current);
    stdout.writeln(
      'Firebase key saved to local .env; Dart options and JSON template sanitized.',
    );
  } on FileSystemException {
    stderr.writeln(
      'Run this tool from the repository root after FlutterFire configuration.',
    );
    exitCode = 1;
  } on FormatException {
    stderr.writeln(
      'Firebase configuration must contain matching Android-only API keys.',
    );
    exitCode = 1;
  }
}
