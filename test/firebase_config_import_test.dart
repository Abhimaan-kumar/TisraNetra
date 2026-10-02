import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../tool/import_firebase_config.dart' as importer;

void main() {
  late Directory directory;
  setUp(() {
    directory = Directory.systemTemp.createTempSync('tisranetra-config-test-');
    Directory('${directory.path}/android/app').createSync(recursive: true);
    Directory('${directory.path}/lib').createSync();
    File(
      '${directory.path}/android/app/google-services.json',
    ).writeAsStringSync(
      jsonEncode({
        'project_info': {'project_id': 'test-project'},
        'client': [
          {
            'client_info': {'mobilesdk_app_id': 'test-app'},
            'api_key': [
              {'current_key': 'test-firebase-key'},
            ],
          },
        ],
      }),
    );
    File('${directory.path}/lib/firebase_options.dart').writeAsStringSync(
      "const options = FirebaseOptions(apiKey: 'test-firebase-key', projectId: 'test-project');\n",
    );
  });
  tearDown(() => directory.deleteSync(recursive: true));

  test(
    'Import removes tracked key literals and preserves other env values',
    () {
      final env = File('${directory.path}/.env');
      const previous =
          'GEMINI_API_KEY=test-gemini-value\nCUSTOM_SETTING=keep-this\n';
      env.writeAsStringSync(previous);
      importer.importFirebaseConfig(directory);
      expect(
        env.readAsStringSync(),
        '${previous}FIREBASE_API_KEY=test-firebase-key\n',
      );
      final source = File(
        '${directory.path}/lib/firebase_options.dart',
      ).readAsStringSync();
      expect(source, contains("String.fromEnvironment('FIREBASE_API_KEY')"));
      expect(source, isNot(contains('test-firebase-key')));
      final template = File(
        '${directory.path}/android/app/google-services.json.template',
      ).readAsStringSync();
      expect(template, isNot(contains('test-firebase-key')));
      expect(
        (jsonDecode(template) as Map)['project_info']['project_id'],
        'test-project',
      );
    },
  );

  test('Switching projects replaces only the existing Firebase entry', () {
    final env = File('${directory.path}/.env');
    env.writeAsStringSync(
      'CUSTOM_SETTING=keep\r\nFIREBASE_API_KEY=old-test-key\r\n',
    );
    importer.importFirebaseConfig(directory);
    expect(
      env.readAsStringSync(),
      'CUSTOM_SETTING=keep\r\nFIREBASE_API_KEY=test-firebase-key\r\n',
    );
  });

  test('Mismatched generated configurations are rejected before mutation', () {
    final source = File('${directory.path}/lib/firebase_options.dart');
    const mismatched =
        "const options = FirebaseOptions(apiKey: 'different-test-key');\n";
    source.writeAsStringSync(mismatched);
    expect(
      () => importer.importFirebaseConfig(directory),
      throwsFormatException,
    );
    expect(source.readAsStringSync(), mismatched);
    expect(File('${directory.path}/.env').existsSync(), isFalse);
    expect(
      File(
        '${directory.path}/android/app/google-services.json.template',
      ).existsSync(),
      isFalse,
    );
  });
}
