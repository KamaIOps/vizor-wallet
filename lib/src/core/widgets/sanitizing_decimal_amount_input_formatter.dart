import 'package:flutter/services.dart';

/// Keeps decimal amount input within the configured precision and length while
/// preserving the user's selection through any sanitization.
class SanitizingDecimalAmountInputFormatter extends TextInputFormatter {
  const SanitizingDecimalAmountInputFormatter({
    required this.maxFractionDigits,
    required this.maxLength,
  });

  final int maxFractionDigits;
  final int maxLength;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final sourceText = newValue.text;
    if (sourceText.isEmpty) return newValue;

    final buffer = StringBuffer();
    final boundaryOffsets = List<int>.filled(sourceText.length + 1, 0);
    var hasDecimal = false;
    for (var index = 0; index < sourceText.length; index++) {
      final codeUnit = sourceText.codeUnitAt(index);
      final character = codeUnit == 0x2C ? '.' : String.fromCharCode(codeUnit);
      if (character == '.') {
        if (!hasDecimal) {
          hasDecimal = true;
          buffer.write(character);
        }
      } else if (codeUnit >= 0x30 && codeUnit <= 0x39) {
        buffer.write(character);
      }
      boundaryOffsets[index + 1] = buffer.length;
    }

    var text = buffer.toString();
    final insertedLeadingZero = text.startsWith('.');
    if (insertedLeadingZero) text = '0$text';
    if (text.length > maxLength) text = text.substring(0, maxLength);
    final decimalIndex = text.indexOf('.');
    if (decimalIndex >= 0) {
      final maxEnd = decimalIndex + 1 + maxFractionDigits;
      if (text.length > maxEnd) text = text.substring(0, maxEnd);
    }

    // Do not reconstruct a valid edit: Flutter may carry a non-collapsed or
    // directional selection and an active composing range that should survive.
    if (text == sourceText) return newValue;

    int mapOffset(int offset) {
      if (offset < 0) return offset;
      final sourceOffset = offset.clamp(0, sourceText.length);
      final mappedOffset =
          boundaryOffsets[sourceOffset] + (insertedLeadingZero ? 1 : 0);
      return mappedOffset.clamp(0, text.length);
    }

    return newValue.copyWith(
      text: text,
      selection: TextSelection(
        baseOffset: mapOffset(newValue.selection.baseOffset),
        extentOffset: mapOffset(newValue.selection.extentOffset),
        affinity: newValue.selection.affinity,
        isDirectional: newValue.selection.isDirectional,
      ),
      composing: TextRange.empty,
    );
  }
}
