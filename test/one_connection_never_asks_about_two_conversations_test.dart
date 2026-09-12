/// One mailbox connection asks about one conversation, and that is the point.
///
/// # What this guards
///
/// The mailbox must not be able to tell that two conversations belong to one
/// person. Section 1 of the threat model is that it cannot, and ADV-4 explains
/// how: a caller presenting nothing is given a fresh capability id per
/// connection, so there is no value tying its requests together.
///
/// A connection that subscribes to the tags of two conversations hands the
/// mailbox exactly that value. It has happened twice. The first change
/// subscribed every conversation's addresses from the live socket so a call in
/// a group nobody had open could be noticed. The second did the same so that
/// messages arrived in conversations that were not on screen. Both were right
/// about what people needed and wrong about how to get it, both passed every
/// test, and both had to come out.
///
/// The first version of this test looked for the shape of the first change in
/// the source, and the second change had a different shape, so it passed. That
/// is what a pattern buys. So the rule is no longer a pattern: it is
/// `SocketOwnership`, every subscription in the service goes through one door
/// that consults it, and this file checks both halves. The object refuses a
/// second conversation, and the service has no other way to subscribe.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rotelyx_chat/rotelyx/rotelyx_service.dart';

void main() {
  group('the rule itself', () {
    test('a socket that speaks for one conversation refuses another', () {
      final rule = SocketOwnership();
      final socket = Object();

      expect(rule.claim(socket, 'alice-and-bob'), isTrue);
      expect(rule.claim(socket, 'alice-and-bob'), isTrue,
          reason: 'the same conversation again is not a second one');
      expect(rule.claim(socket, 'the-book-club'), isFalse,
          reason: 'this is the whole rule');
      expect(rule.ownerOf(socket), 'alice-and-bob',
          reason: 'a refused claim changes nothing');
    });

    test('two sockets may speak for two conversations', () {
      final rule = SocketOwnership();
      expect(rule.claim(Object(), 'alice-and-bob'), isTrue);
      expect(rule.claim(Object(), 'the-book-club'), isTrue);
    });

    test('a released socket starts clean', () {
      // The socket for the conversation on screen is replaced when somebody
      // opens a different one. The new socket must not inherit the old claim,
      // or opening a second conversation would be refused as a second one.
      final rule = SocketOwnership();
      final socket = Object();
      expect(rule.claim(socket, 'alice-and-bob'), isTrue);
      rule.release(socket);
      expect(rule.ownerOf(socket), isNull);
      expect(rule.claim(socket, 'the-book-club'), isTrue);
    });
  });

  group('the service has one door', () {
    final service =
        File('lib/rotelyx/rotelyx_service.dart').readAsStringSync();

    test('every subscription goes through the door that consults the rule',
        () {
      // Count the calls to the mailbox client's `subscribe`. There must be
      // exactly one, inside `_subscribeFor`, which is the method that asks
      // `SocketOwnership` first. A second call site is a way around the rule,
      // whatever it is for.
      final calls = RegExp(r'\.subscribe\(').allMatches(service).length;
      expect(calls, 1,
          reason: 'something subscribes to the mailbox without going through '
              '_subscribeFor. One connection asking about several '
              'conversations tells the mailbox they belong to one device, '
              'which is the first thing the threat model says it cannot '
              'learn. Route it through _subscribeFor, and if it is for '
              'another conversation, give it a socket of its own.');

      final door = RegExp(
        r'void _subscribeFor\([^)]*\)\s*\{[\s\S]{0,600}?_ownership\.claim\(',
      );
      expect(door.hasMatch(service), isTrue,
          reason: '_subscribeFor no longer consults SocketOwnership before '
              'subscribing');
    });

    test('background conversations each open a socket of their own', () {
      // The shape that keeps the promise: inside the function that listens on
      // every other conversation, a new client is constructed. If somebody
      // rewrites it to reuse the live socket, this is the line that goes.
      final listens = RegExp(
        r'_listenEverywhereElse\(\)[\s\S]{0,3000}?MailboxClient\(url\)',
      );
      expect(listens.hasMatch(service), isTrue,
          reason: 'listening on other conversations no longer opens a '
              'connection per conversation');
    });
  });
}
