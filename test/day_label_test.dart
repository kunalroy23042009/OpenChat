import 'package:flutter_test/flutter_test.dart';
import 'package:open_chat/src/chat/day_label.dart';

void main() {
  test('sameDay compares calendar days', () {
    expect(sameDay(DateTime(2026, 10, 13, 1), DateTime(2026, 10, 13, 23)), isTrue);
    expect(sameDay(DateTime(2026, 10, 13), DateTime(2026, 10, 14)), isFalse);
    expect(sameDay(DateTime(2026, 12, 31), DateTime(2027, 1, 1)), isFalse);
  });

  test('dayLabel renders today, yesterday, and dates', () {
    final now = DateTime.now();
    expect(dayLabel(now), 'Today');
    expect(dayLabel(now.subtract(const Duration(days: 1))), 'Yesterday');
    final older = DateTime(now.year, now.month, now.day).subtract(const Duration(days: 5));
    expect(dayLabel(older), contains(older.day.toString()));
    final lastYear = DateTime(now.year - 1, 3, 4);
    expect(dayLabel(lastYear), contains((now.year - 1).toString()));
  });
}
