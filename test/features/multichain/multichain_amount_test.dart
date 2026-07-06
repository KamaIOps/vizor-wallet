import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/features/multichain/domain/multichain_chain.dart';

void main() {
  group('parseMultichainAmount', () {
    test('parses whole and fractional amounts into base units', () {
      expect(parseMultichainAmount('1', 8), BigInt.from(100000000));
      expect(parseMultichainAmount('0.00000001', 8), BigInt.one);
      expect(parseMultichainAmount('1.5', 18), BigInt.parse('1500000000000000000'));
      expect(parseMultichainAmount('12.345678', 6), BigInt.from(12345678));
    });

    test('rejects malformed input', () {
      expect(parseMultichainAmount('', 8), isNull);
      expect(parseMultichainAmount('1,5', 8), isNull);
      expect(parseMultichainAmount('-1', 8), isNull);
      expect(parseMultichainAmount('1.2.3', 8), isNull);
      expect(parseMultichainAmount('abc', 8), isNull);
      // More fractional digits than the chain supports.
      expect(parseMultichainAmount('0.123456789', 8), isNull);
    });
  });

  group('formatMultichainAmount', () {
    test('formats base units without trailing zeros', () {
      expect(formatMultichainAmount(BigInt.from(100000000), 8), '1');
      expect(formatMultichainAmount(BigInt.one, 8), '0.00000001');
      expect(formatMultichainAmount(BigInt.from(12345678), 6), '12.345678');
      expect(formatMultichainAmount(BigInt.zero, 9), '0');
    });

    test('round-trips with parse', () {
      const cases = [('0.5', 8), ('1234.000001', 6), ('7', 18)];
      for (final (text, decimals) in cases) {
        final parsed = parseMultichainAmount(text, decimals)!;
        expect(formatMultichainAmount(parsed, decimals), text);
      }
    });
  });
}
