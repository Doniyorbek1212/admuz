/// Phone numbers written in a message, as international digits without "+" (e.g. "998901234567").
///
/// Accepts "+" plus a country code in any grouping, Uzbek numbers with or without 998 ("90 123 45 67", "998 90 123-45-67")
/// and Russian/Kazakh "+7"/"8 9xx" numbers. Other digit runs (order ids, card numbers, dates) are ignored.
List<String> phoneNumbersIn(String text, {int max = 3}) {
  final found = <String>[];
  for (final match in _candidate.allMatches(text)) {
    final raw = match.group(0)!;
    final digits = raw.replaceAll(RegExp(r'\D'), '');
    final number = switch (digits.length) {
      _ when raw.startsWith('+') => digits.length >= 10 && digits.length <= 15 ? digits : null,
      9 => '998$digits',
      12 when digits.startsWith('998') => digits,
      11 when digits.startsWith('8') && digits[1] == '9' => '7${digits.substring(1)}',
      11 when digits.startsWith('7') => digits,
      _ => null,
    };
    if (number != null && !found.contains(number)) found.add(number);
    if (found.length == max) break;
  }
  return found;
}

// A digit run with phone-style separators, not glued to other digits or letters.
final _candidate = RegExp(r'(?<![\w+])\+?\d[\d \-().]{6,18}\d(?![\w])');
