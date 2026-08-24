// Mints meeting codes with the client's own implementation, so the Rust side
// can be tested against codes this file did not produce.
import 'package:rotelyx_chat/rotelyx/meeting_code.dart';

void main() {
  for (var i = 0; i < 3; i++) {
    final code = newMeetingCode();
    print('$code  |  ${prettyMeetingCode(code)}');
  }
}
