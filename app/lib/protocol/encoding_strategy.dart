import 'dart:convert';

import 'package:gbk_codec/gbk_codec.dart';

const int attemptCount = 2;

class ByteLengths {
  const ByteLengths({required this.utf8, required this.gbk});

  final int utf8;
  final int? gbk;
}

List<int> encodeAttempt(String input, int attempt) {
  if (attempt < 0 || attempt >= attemptCount) {
    throw RangeError.range(attempt, 0, attemptCount - 1, 'attempt');
  }
  if (attempt == 0) {
    return utf8.encode(input);
  }
  return _encodeGbk(input);
}

ByteLengths byteLengthForDisplay(String input) {
  final utf8Length = utf8.encode(input).length;
  int? gbkLength;
  try {
    gbkLength = _encodeGbk(input).length;
  } on FormatException {
    gbkLength = null;
  }
  return ByteLengths(utf8: utf8Length, gbk: gbkLength);
}

List<int> _encodeGbk(String input) {
  final out = gbk_bytes.encode(input);
  for (final b in out) {
    if (b < 0 || b > 0xff) {
      throw FormatException('not GBK-encodable: $input');
    }
  }
  return out;
}
