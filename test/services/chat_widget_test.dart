import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/models/contact.dart';
import 'package:meshcore_open/models/message.dart';
import 'package:meshcore_open/services/chat_widget_service.dart';

Contact _contact({
  required String name,
  String? customName,
  required DateTime lastMessageAt,
  bool isActive = true,
  int keySeed = 1,
}) {
  final key = Uint8List(32);
  for (var i = 0; i < key.length; i++) {
    key[i] = (i * keySeed) & 0xFF;
  }
  return Contact(
    publicKey: key,
    name: name,
    customName: customName,
    type: 0,
    pathLength: -1,
    path: Uint8List(0),
    lastSeen: lastMessageAt,
    lastMessageAt: lastMessageAt,
    isActive: isActive,
  );
}

Message _msg(String text, DateTime at, {bool outgoing = false}) {
  final key = Uint8List(32);
  return Message(
    senderKey: key,
    text: text,
    timestamp: at,
    isOutgoing: outgoing,
    isCli: false,
  );
}

void main() {
  final t1 = DateTime(2026, 9, 17, 10);
  final t2 = DateTime(2026, 9, 17, 11);
  final t3 = DateTime(2026, 9, 17, 12);

  group('ChatWidgetService.pickContact', () {
    test('picks the contact with the latest lastMessageAt', () {
      final a = _contact(name: 'A', lastMessageAt: t1);
      final b = _contact(name: 'B', lastMessageAt: t3);
      final c = _contact(name: 'C', lastMessageAt: t2);
      expect(ChatWidgetService.pickContact([a, b, c])!.name, 'B');
    });

    test('skips inactive contacts', () {
      final a = _contact(name: 'A', lastMessageAt: t3, isActive: false);
      final b = _contact(name: 'B', lastMessageAt: t1);
      expect(ChatWidgetService.pickContact([a, b])!.name, 'B');
    });

    test('empty list yields null', () {
      expect(ChatWidgetService.pickContact([]), isNull);
    });

    test('pinned contact wins when present and active', () {
      final a = _contact(name: 'A', lastMessageAt: t3, keySeed: 1);
      final b = _contact(name: 'B', lastMessageAt: t1, keySeed: 2);
      final pinned = ChatWidgetService.pickContact(
        [a, b],
        pinnedKeyHex: b.publicKeyHex,
      );
      expect(pinned!.name, 'B'); // older, but explicitly pinned
    });

    test('pinned but missing/inactive falls back to latest', () {
      final a = _contact(name: 'A', lastMessageAt: t3, keySeed: 1);
      final gone = _contact(
        name: 'Gone', lastMessageAt: t2, isActive: false, keySeed: 3,
      );
      // pinned key matches only the inactive contact
      final r = ChatWidgetService.pickContact(
        [a, gone],
        pinnedKeyHex: gone.publicKeyHex,
      );
      expect(r!.name, 'A');
      // pinned key matches nothing at all
      expect(ChatWidgetService.pickContact([a], pinnedKeyHex: 'zz'), a);
    });
  });

  group('ChatWidgetService.format', () {
    test('shows last message with outgoing prefix', () {
      final c = _contact(name: 'Advertised', customName: 'Gem', lastMessageAt: t1);
      final data = ChatWidgetService.format(
        c,
        [_msg('older', t1), _msg('ping', t2), _msg('hello there', t3, outgoing: true)],
        2,
      );
      expect(data.title, 'Gem'); // custom name wins
      expect(data.message, 'You: hello there');
      expect(data.time, t3);
      expect(data.unread, 2);
      expect(data.chatKeyHex, c.publicKeyHex);
    });

    test('incoming message has no prefix', () {
      final c = _contact(name: 'A', lastMessageAt: t1);
      final data = ChatWidgetService.format(c, [_msg('hi', t2)], 0);
      expect(data.message, 'hi');
    });

    test('no messages falls back to placeholder + contact timestamp', () {
      final c = _contact(name: 'A', lastMessageAt: t2);
      final data = ChatWidgetService.format(c, [], 0);
      expect(data.message, 'No messages yet');
      expect(data.time, t2);
    });
  });
}
