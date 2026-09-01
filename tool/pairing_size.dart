/// What the pairing envelopes weigh, against what the free tier accepts.
///
/// An ordinary message is 1.4 kB. The handshake is not an ordinary message: it
/// carries a key package, a welcome and a ratchet tree, and those grow with the
/// group. If one of them is over the tier's ceiling the mailbox refuses it, and
/// the pairing fails at the moment the code is confirmed.
library;

import 'dart:io';
import 'package:rotelyx_chat/rotelyx/engine/native.dart';
import 'package:rotelyx_chat/rotelyx/rotelyx_wasm.dart';

void main() {
  final engine = createEngine();
  final host = engine.newSession('host');
  host.found();

  final guest = engine.newSession('guest');

  final tag = RotelyxWasm.rendezvousTag('a phrase for measuring only');

  void show(String what, String b64) {
    final sealed = RotelyxWasm.sealUnder(tag, b64);
    stdout.writeln('  ${what.padRight(16)} raw ${b64.length.toString().padLeft(7)} B   '
        'sealed ${sealed.length.toString().padLeft(7)} B');
  }

  stdout.writeln('\n  the free tier accepts 65536 B of payload\n');

  final keyPackage = guest.keyPackage();
  show('key package', keyPackage);

  final inv = host.invite(keyPackage);
  show('welcome', inv.welcome);
  show('ratchet tree', inv.ratchetTree);

  guest.join(inv.welcome, inv.ratchetTree);

  final hybrid = guest.hybridPublicKey();
  show('hybrid key', hybrid);

  final wrapped = host.beginGroupPq([hybrid]);
  for (final w in wrapped) {
    show('pq wrapped', w);
  }
  final commit = host.commitPq();
  show('pq commit', commit);
}
