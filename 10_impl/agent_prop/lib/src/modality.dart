/// C7: Prop modality is text in, text out. The only transformation is
/// normalization before the loop runs; the one binary input is a coding
/// task's image, supplied as an `@path` token on the goal line (C6).
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import 'models.dart';

String normalizeToText(String raw) => raw.trim();

/// Image extensions an `@path` token may name (C7: coding-only image input).
const Set<String> kImageExtensions = {'.png', '.jpg', '.jpeg', '.gif', '.webp'};

/// A goal after C7 normalization: the text with `@path` tokens stripped, and
/// the images those tokens named, loaded once at submission.
final class ParsedGoal {
  const ParsedGoal(this.text, this.images);
  final String text;
  final List<ImageAttachment> images;
}

/// Parse a goal line: strip whitespace-separated `@path` tokens, validate
/// each (the path must exist and be an image file), and load its bytes.
/// Throws a [FormatException] naming the bad token.
ParsedGoal parseGoal(String raw) {
  final words = raw.split(RegExp(r'\s+'));
  final images = <ImageAttachment>[];
  final textWords = <String>[];
  for (final word in words) {
    if (!word.startsWith('@') || word.length < 2) {
      textWords.add(word);
      continue;
    }
    final path = word.substring(1);
    final file = File(p.absolute(path));
    if (!file.existsSync()) {
      throw FormatException('attachment not found: $path');
    }
    if (!kImageExtensions.contains(p.extension(path).toLowerCase())) {
      throw FormatException('attachment is not an image '
          '(${kImageExtensions.join(', ')}): $path');
    }
    images.add(ImageAttachment(path: path, bytes: file.readAsBytesSync()));
  }
  return ParsedGoal(
    normalizeToText(textWords.join(' ')),
    images,
  );
}

/// Like [parseGoal], but reports failure through the return value.
ParsedGoal? tryParseGoal(String raw) {
  try {
    return parseGoal(raw);
  } on FormatException {
    return null;
  }
}

/// The message a failed [parseGoal] would have thrown; empty when valid.
String goalErrorMessage(String raw) {
  try {
    parseGoal(raw);
    return '';
  } on FormatException catch (e) {
    return e.message;
  }
}
