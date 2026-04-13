import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

// ── Text segment (used for per-language TTS) ──────────────────────────────────

enum TextScript { latin, devanagiri }

class TextSegment {
  final String text;
  final TextScript script;
  const TextSegment(this.text, this.script);
}

// ── Result ────────────────────────────────────────────────────────────────────

class ReadAnythingResult {
  final String text;              // full combined text (for display)
  final List<TextSegment> segments; // ordered segments for per-language TTS
  final bool hasText;
  final String? errorReason;

  const ReadAnythingResult({
    required this.text,
    required this.segments,
    required this.hasText,
    this.errorReason,
  });

  static const ReadAnythingResult noText = ReadAnythingResult(
    text: '',
    segments: [],
    hasText: false,
  );
}

// ── Service ───────────────────────────────────────────────────────────────────
//
// Runs ML Kit recognizer with Devanagari script.
// Important: ML Kit's Devanagari script natively recognizes BOTH Hindi and English!
// This avoids fatal native crashes caused by running two recognizers concurrently
// on the same image.
//
// On-device, offline, ~150-400 ms.
//
class ReadAnythingService {
  final TextRecognizer _recognizer =
      TextRecognizer(script: TextRecognitionScript.devanagiri);

  bool _disposed = false;

  // Regex: any Devanagari codepoint U+0900–U+097F
  static final RegExp _devanagiriRange = RegExp(r'[\u0900-\u097F]');

  /// Extract text from [imagePath].
  Future<ReadAnythingResult> extractText(String imagePath) async {
    if (_disposed) {
      return const ReadAnythingResult(
        text: '',
        segments: [],
        hasText: false,
        errorReason: 'Service disposed',
      );
    }

    try {
      final inputImage = InputImage.fromFilePath(imagePath);

      // A single recognizer efficiently reads both Hindi and English
      final recognizedText = await _recognizer.processImage(inputImage);

      // Process and split into segments for bilingual TTS
      final segments = _processBlocks(recognizedText);
      if (segments.isEmpty) return ReadAnythingResult.noText;

      final fullText = segments.map((s) => s.text).join('\n').trim();
      return ReadAnythingResult(
        text: fullText,
        segments: segments,
        hasText: true,
      );
    } on Exception catch (e) {
      return ReadAnythingResult(
        text: '',
        segments: [],
        hasText: false,
        errorReason: e.toString(),
      );
    }
  }

  /// Extracts blocks and combines them into segments by language
  List<TextSegment> _processBlocks(RecognizedText recognizedText) {
    // Collect and pair each block with its vertical position
    final blocks = <_ScoredBlock>[];

    for (final block in recognizedText.blocks) {
      final text = block.text.trim();
      if (text.isEmpty) continue;
      final y = block.boundingBox.top;
      blocks.add(_ScoredBlock(text: text, y: y));
    }

    if (blocks.isEmpty) return [];

    // Sort by vertical position to preserve reading order
    blocks.sort((a, b) => a.y.compareTo(b.y));

    // Convert to segments, merging consecutive same-script paragraphs
    final segments = <TextSegment>[];
    for (final block in blocks) {
      final script = _scriptOf(block.text);
      final cleanText = _cleanText(block.text);
      if (cleanText.isEmpty) continue;

      if (segments.isNotEmpty && segments.last.script == script) {
        // Append to the last segment
        final last = segments.removeLast();
        segments.add(TextSegment('${last.text}\n$cleanText', script));
      } else {
        segments.add(TextSegment(cleanText, script));
      }
    }

    return segments;
  }

  /// Determine the dominant script of [text].
  TextScript _scriptOf(String text) {
    final devaChars = _devanagiriRange.allMatches(text).length;
    // If more than 15 % of chars are Devanagari, treat as Devanagiri
    final ratio = text.isEmpty ? 0.0 : devaChars / text.length;
    return ratio >= 0.15 ? TextScript.devanagiri : TextScript.latin;
  }

  /// Remove excessive blank lines inside a block.
  String _cleanText(String raw) {
    final lines = raw.split('\n');
    final buffer = StringBuffer();
    int blankRun = 0;
    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) {
        blankRun++;
        if (blankRun == 1) buffer.writeln();
      } else {
        blankRun = 0;
        buffer.writeln(trimmed);
      }
    }
    return buffer.toString().trim();
  }

  /// Release native ML Kit resources.
  void dispose() {
    if (!_disposed) {
      _disposed = true;
      _recognizer.close();
    }
  }
}

// Internal helper for tracking block vertical scroll
class _ScoredBlock {
  final String text;
  final double y;
  _ScoredBlock({required this.text, required this.y});
}