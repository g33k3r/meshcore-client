import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/services/chat_history_backup.dart';
import 'package:meshcore_open/storage/drift/blob_store.dart';
import 'package:meshcore_open/storage/drift/offband_database.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

/// Chat-history backup round-trip and merge safety.
///
/// The stakes: an import that replaces instead of merging can silently drop
/// newer messages; an import that fabricates records can corrupt the store.
/// Both failure modes are tested, not just the happy path.
void main() {
  late OffbandDatabase db;
  late BlobStore store;
  late Directory tmpDir;

  setUp(() async {
    db = OffbandDatabase(NativeDatabase.memory());
    store = BlobStore(db);
    BlobStore.overrideForTest(store);
    PrefsManager.reset();
    SharedPreferences.setMockInitialValues({});
    await PrefsManager.initialize();
    tmpDir = await Directory.systemTemp.createTemp('geekcore-backup-test');
    PathProviderPlatform.instance = _FakePathProvider(tmpDir.path);
  });

  tearDown(() async {
    BlobStore.clearTestOverride();
    await db.close();
    await tmpDir.delete(recursive: true);
  });

Future<List<dynamic>> readList(String key) async =>
      jsonDecode((await store.read(key))!) as List<dynamic>;

    String messageArray(List<Map<String, dynamic>> records) =>
      jsonEncode(records);

  Map<String, dynamic> message(
    String id,
    int ts, {
    bool outgoing = false,
    String text = 'hello',
  }) => {
    'messageId': id,
    'senderKey': 'a2V5', // base64-ish placeholder, raw merge never decodes it
    'timestamp': ts,
    'text': text,
    'isOutgoing': outgoing,
  };

  String backupPayload(Map<String, String> blobs) => jsonEncode({
    'format': ChatHistoryBackup.formatId,
    'version': ChatHistoryBackup.formatVersion,
    'exportedAt': '2026-09-18T00:00:00',
    'blobs': blobs,
  });

  test('export collects message and contacts blobs, nothing else', () async {
    await store.write('messages_abc123cont1', messageArray([message('m1', 1)]));
    await store.write('channel_messages_abc0', messageArray([message('c1', 2)]));
    await store.write('contactsabc123', '[{"publicKey":"cGs="}]');
    await store.write('unrelated_key', 'nope');

    final file = await ChatHistoryBackup().exportToFile();
    expect(file, isNotNull);
    final doc = jsonDecode(await file!.readAsString()) as Map<String, dynamic>;
    expect(doc['format'], ChatHistoryBackup.formatId);
    final blobs = doc['blobs'] as Map<String, dynamic>;
    expect(blobs.keys, containsAll(['messages_abc123cont1', 'channel_messages_abc0', 'contactsabc123']));
    expect(blobs.keys, isNot(contains('unrelated_key')));
  });

  test('export returns null when nothing is stored', () async {
    expect(await ChatHistoryBackup().exportToFile(), isNull);
  });

  test('import restores messages into an empty store, sorted by time',
      () async {
    final backup = backupPayload({
      'messages_abc123cont1': messageArray([message('m2', 200), message('m1', 100)]),
    });

    final result = await ChatHistoryBackup().importFromJson(backup);

    expect(result.messageKeysWritten, 1);
    expect(result.messagesRestored, 2);
    final restored = await readList('messages_abc123cont1');
    expect(restored.length, 2);
    expect(restored[0]['messageId'], 'm1');
    expect(restored[1]['messageId'], 'm2');
  });

  test('import MERGES with existing history and keeps newer records intact',
      () async {
    await store.write(
      'messages_abc123cont1',
      messageArray([message('old-1', 100), message('current-1', 300)]),
    );

    final result = await ChatHistoryBackup().importFromJson(backupPayload({
      'messages_abc123cont1': messageArray([
        message('old-1', 100, text: 'same id, backup copy'),
        message('backup-only', 200),
      ]),
    }));

    // Dedupe by id: 'old-1' exists once; 'backup-only' added; 'current-1' kept.
    final restored = await readList('messages_abc123cont1');
    final ids = restored.map((r) => r['messageId']).toSet();
    expect(ids, {'old-1', 'backup-only', 'current-1'});
    expect(result.messagesRestored, 1);
    expect(result.messageKeysWritten, 1);
    // Sorted by timestamp.
    expect(
      restored.map((r) => r['timestamp'] as int).toList(),
      everyElement(isNotNull),
    );
    final stamps = restored.map((r) => r['timestamp'] as int).toList();
    expect(stamps, [100, 200, 300]);
  });

  test('fallback identity dedupes records without messageId', () async {
    final record = <String, dynamic>{
      'senderKey': 'a2V5',
      'timestamp': 500,
      'text': 'no id here',
    };
    await store.write(
      'messages_abc123cont1',
      messageArray([record, message('other', 100)]),
    );

    await ChatHistoryBackup().importFromJson(backupPayload({
      'messages_abc123cont1': messageArray([
        {'senderKey': 'a2V5', 'timestamp': 500, 'text': 'no id here'},
        {'senderKey': 'a2V5', 'timestamp': 600, 'text': 'no id here'},
      ]),
    }));

    final restored = await readList('messages_abc123cont1');
    expect(restored.length, 3); // dup collapsed, one new added
    expect(restored.map((r) => r['timestamp']), containsAll([500, 600, 100]));
  });

  test('import fills user-owned contact fields but never overwrites',
      () async {
    await store.write(
      'contactsabc123',
      jsonEncode([
        {
          'publicKey': 'cGs=',
          'name': 'device-name',
          'customName': 'Kept Name',
        },
        {'publicKey': 'b3RoZXI=', 'name': 'no-backup-overlay'},
      ]),
    );

    final result = await ChatHistoryBackup().importFromJson(backupPayload({
      'contactsabc123': jsonEncode([
        {
          'publicKey': 'cGs=',
          'name': 'stale-device-name',
          'customName': 'Backup Name',
          'pathOverride': 'direct',
        },
        {
          'publicKey': 'b3RoZXI=',
          'name': 'irrelevant',
          'customName': 'Fresh Nickname',
        },
        {
          'publicKey': 'Z2hvc3Q=',
          'name': 'contact the device no longer has',
        },
      ]),
    }));

    final contacts = await readList('contactsabc123');
    final byKey = {
      for (final c in contacts) c['publicKey'] as String: c as Map<String, dynamic>,
    };
    // Existing customName wins; missing pathOverride filled from backup.
    expect(byKey['cGs=']!['customName'], 'Kept Name');
    expect(byKey['cGs=']!['pathOverride'], 'direct');
    expect(byKey['cGs=']!['name'], 'device-name');
    // Contact absent from backup untouched.
    expect(byKey['b3RoZXI=']!['name'], 'no-backup-overlay');
    // Ghost contact NOT resurrected.
    expect(byKey.containsKey('Z2hvc3Q='), isFalse);
    // customName fill + pathOverride fill = 2 restored settings.
    expect(result.contactSettingsRestored, 2);
  });

  test('rejects foreign or invalid payloads without touching the store',
      () async {
    await store.write('messages_abc123cont1', messageArray([message('m1', 1)]));
    final before = await store.read('messages_abc123cont1');

    expect(
      () => ChatHistoryBackup().importFromJson('{"format":"other","version":1}'),
      throwsFormatException,
    );
    expect(
      () => ChatHistoryBackup().importFromJson('not json at all'),
      throwsFormatException,
    );
    expect(
      () => ChatHistoryBackup().importFromJson(
        jsonEncode({
          'format': ChatHistoryBackup.formatId,
          'version': 99,
          'blobs': {},
        }),
      ),
      throwsFormatException,
    );
    expect(await store.read('messages_abc123cont1'), before);
  });

  test('skips unreadable blobs, imports the rest', () async {
    final result = await ChatHistoryBackup().importFromJson(backupPayload({
      'messages_abc123cont1': messageArray([message('m1', 1)]),
      'messages_abc123cont2': '}}}not-an-array{{{',
      'unknown_family': '["whatever"]',
    }));

    expect(result.messageKeysWritten, 1);
    expect(result.skippedKeys, 2);
    expect((await readList('messages_abc123cont1')).length, 1);
    expect(await store.read('messages_abc123cont2'), isNull);
    expect(await store.read('unknown_family'), isNull);
  });
}

class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.tmp);

  final String tmp;

  @override
  Future<String?> getTemporaryPath() async => tmp;
}
