/// Proof that what the watch draws is a code a camera can read.
///
/// The watch holds no encoder. It is sent the squares by
/// `lib/rotelyx/qr_matrix.dart` and paints them, so the only thing that can go
/// wrong between the phone minting a meeting code and somebody scanning it off
/// a wrist is the matrix itself: the wrong orientation, a transposed row, a
/// symbol that is not square.
///
/// So this feeds the rows to the application's own decoder — the one behind the
/// camera in `lib/qr/decode.dart` — and checks the code comes back. If the
/// watch ever shows something unreadable, this fails first.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:rotelyx_chat/qr/decode.dart';
import 'package:rotelyx_chat/rotelyx/meeting_code.dart';
import 'package:rotelyx_chat/rotelyx/qr_matrix.dart';

/// The rows, back in the shape the decoder wants.
QrMatrix matrixOf(List<String> rows) {
  final m = QrMatrix(rows.length);
  for (var row = 0; row < rows.length; row++) {
    for (var col = 0; col < rows.length; col++) {
      m.set(row, col, rows[row].codeUnitAt(col) == 0x31);
    }
  }
  return m;
}

void main() {
  test('a meeting code survives the trip to the wrist and back', () {
    final code = newMeetingCode();
    final rows = qrRows(code);

    expect(decodeMatrix(matrixOf(rows))?.text, code);
  });

  test('the rows are a square of noughts and ones', () {
    final rows = qrRows(newMeetingCode());

    // Version 4. `meeting_code.dart` chose 120 bits of entropy so that the
    // symbol stays at 33 modules across, which is what keeps it readable at
    // the size a watch can draw it. A code that grew past this would still
    // scan on a phone and quietly stop scanning off a wrist.
    expect(rows.length, 33);
    for (final row in rows) {
      expect(row.length, 33);
      expect(RegExp(r'^[01]+$').hasMatch(row), isTrue);
    }
  });

  test('every code encodes, not just a lucky one', () {
    for (var i = 0; i < 50; i++) {
      final code = newMeetingCode();
      expect(decodeMatrix(matrixOf(qrRows(code)))?.text, code);
    }
  });
}
