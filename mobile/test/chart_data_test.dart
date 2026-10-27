import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sado/features/profile/statistics_screen.dart';

void main() {
  test('parses Telegram statistics chart JSON into series without the x column', () {
    const json = '{"columns":[["x",1,2,3],["y0",5,6,7],["y1",1,0,2]],'
        '"types":{"x":"x","y0":"line","y1":"line"},'
        '"names":{"y0":"Joined","y1":"Left"},'
        '"colors":{"y0":"GREEN#4BD04B","y1":"#FF0000"}}';

    final data = ChartData.parse(json)!;

    expect(data.isPie, isFalse);
    expect(data.series.map((s) => s.name), ['Joined', 'Left']);
    expect(data.series.first.values, [5, 6, 7]);
    expect(data.series.first.color, const Color(0xFF4BD04B));
    expect(data.series.last.color, const Color(0xFFFF0000));
  });

  test('flags pie charts and rejects malformed JSON', () {
    expect(ChartData.parse('{"columns":[["y0",3]],"types":{"y0":"pie"},"names":{},"colors":{}}')!.isPie, isTrue);
    expect(ChartData.parse('not json'), isNull);
    expect(ChartData.parse('{"columns":[[1,2]]}'), isNull);
  });
}
