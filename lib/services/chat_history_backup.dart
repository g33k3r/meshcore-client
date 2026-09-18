import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../storage/drift/blob_store.dart';
import '../utils/app_logger.dart';

/// Outcome of an import, for user-facing feedback and tests.
class ChatBackupResult {
  const ChatBackupResult({
    required this.messageKeysWritten,
    required this.messagesRestored,
    required this.contactSettingsRestored,
    required this.skippedKeys,
  });

  /// Per-contact / per-channel history keys written (merged or created).
  final int messageKeysWritten;

  /// Total message records restored across those keys (after merge-dedupe).
  final int messagesRestored;

  /// Contacts whose user-owned settings (custom name, path override) were
  /// restored. Contacts themselves are NEVER created by an import — the
  /// device's contact list is the source of truth for who exists.
  final int contactSettingsRestored;

  /// Backup keys skipped: unparseable payloads or unknown key families.
  final int skippedKeys;

  bool get nothingDone =>
      messageKeysWritten == 0 &&
      contactSettingsRestored == 0 &&
      skippedKeys == 0;
}

/// Portable chat-history backup: export every stored conversation (DMs,
/// channels) plus per-contact user settings (custom names, path overrides) to
/// a single JSON file the user keeps, and merge it back after a reinstall.
///
/// The app's drift database survives in-place updates, but an
/// uninstall/reinstall wipes it — and a mesh node running repeater firmware
/// does not re-serve history, so without this file the chats are gone.
///
/// Design notes:
/// - Blobs are exported RAW (the exact JSON strings the stores persist), so
///   restore needs no model-version translation: whatever the exporting build
///   wrote, the importing build reads through the store's own decoder.
/// - Import MERGES by the same identity the stores use for merge-on-save
///   (messageId, else sender/timestamp/text composite) rather than replacing,
///   so importing an older backup over newer chats cannot lose messages.
/// - Contacts are merged by public key and only ever contribute user-owned
///   fields (customName, pathOverride*); device-synced fields stay fresh.
class ChatHistoryBackup {
  static const String formatId = 'geekcore-chat-backup';
  static const int formatVersion = 1;

  /// Contact fields that belong to the USER, not the device: an import may
  /// fill them in, but never overwrite device-synced contact data.
  static const List<String> _userOwnedContactFields = [
    'customName',
    'pathOverride',
    'pathOverrideBytes',
  ];

  static const List<String> _messagePrefixes = [
    'messages_',
    'channel_messages_',
  ];
  static const String _contactsPrefix = 'contacts';

  /// Collects every backup-relevant blob and writes a single timestamped JSON
  /// file to the temp directory. Returns the file, or null when there is
  /// nothing stored to back up.
  Future<File?> exportToFile() async {
    final blobs = BlobStore.instance;
    final payload = <String, String>{};
    for (final prefix in [..._messagePrefixes, _contactsPrefix]) {
      for (final key in await blobs.keysWithPrefix(prefix)) {
        final value = await blobs.read(key);
        if (value != null && value.isNotEmpty) payload[key] = value;
      }
    }
    if (payload.isEmpty) return null;

    final doc = {
      'format': formatId,
      'version': formatVersion,
      'exportedAt': DateTime.now().toIso8601String(),
      'blobs': payload,
    };
    final dir = await getTemporaryDirectory();
    final stamp = DateFormat('yyyyMMdd-HHmm').format(DateTime.now());
    final file = File('${dir.path}/geekcore-backup-$stamp.json');
    await file.writeAsString(jsonEncode(doc), flush: true);
    return file;
  }

  /// Shares the exported file (app sheet: save to Drive/Files/Downloads).
  /// Returns true when the user completed a share action.
  Future<bool> exportAndShare() async {
    final file = await exportToFile();
    if (file == null) return false;
    final result = await SharePlus.instance.share(
      ShareParams(
        subject: 'GeekCore chat history',
        files: [XFile(file.path)],
      ),
    );
    return result.status == ShareResultStatus.success;
  }
  /// Imports from a picked file path.
  Future<ChatBackupResult> importFromFile(String path) async {
    return importFromJson(await File(path).readAsString());
  }

  /// Imports from raw backup JSON. Throws [FormatException] when the payload
  /// is not a GeekCore backup of a known version; individual broken blobs are
  /// skipped and counted, not fatal.
  Future<ChatBackupResult> importFromJson(String raw) async {
    final Object decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (e) {
      throw FormatException('Not valid JSON: $e');
    }
    if (decoded is! Map<String, dynamic> ||
        decoded['format'] != formatId ||
        decoded['version'] != formatVersion) {
      throw const FormatException(
        'Not a GeekCore chat backup (unknown format/version)',
      );
    }
    final blobs = decoded['blobs'];
    if (blobs is! Map<String, dynamic>) {
      throw const FormatException('Backup has no blobs object');
    }

    final store = BlobStore.instance;
    var messageKeys = 0;
    var messages = 0;
    var contactSettings = 0;
    var skipped = 0;

    for (final entry in blobs.entries) {
      final key = entry.key;
      final value = entry.value;
      if (value is! String || value.isEmpty) {
        skipped++;
        continue;
      }
      try {
        if (_messagePrefixes.any(key.startsWith)) {
          final count = await _mergeMessageBlob(store, key, value);
          messageKeys++;
          messages += count;
        } else if (key.startsWith(_contactsPrefix)) {
          contactSettings += await _mergeContactsBlob(store, key, value);
        } else {
          skipped++;
        }
      } catch (e) {
        appLogger.warn(
          'Chat backup: skipping blob $key (${e.runtimeType}): $e',
          tag: 'Backup',
        );
        skipped++;
      }
    }

    return ChatBackupResult(
      messageKeysWritten: messageKeys,
      messagesRestored: messages,
      contactSettingsRestored: contactSettings,
      skippedKeys: skipped,
    );
  }

  /// Merge-on-write for message-history blobs, mirroring the stores'
  /// merge-on-save semantics: upsert by identity, never truncate.
  Future<int> _mergeMessageBlob(
    BlobStore store,
    String key,
    String imported,
  ) async {
    final importedList = _decodeRecordList(imported);
    final existing = await store.read(key);
    if (existing != null && existing.isNotEmpty) {
      try {
        final existingList = _decodeRecordList(existing);
        final merged = <String, Map<String, dynamic>>{};
        for (final record in existingList) {
          merged[recordIdentity(record)] = record;
        }
        var restored = 0;
        for (final record in importedList) {
          final id = recordIdentity(record);
          if (!merged.containsKey(id)) {
            merged[id] = record;
            restored++;
          }
        }
        await store.write(key, _encodeSorted(merged.values));
        return restored;
      } catch (e) {
        // Existing blob unparseable: prefer the backup over a broken store.
        appLogger.warn(
          'Chat backup: stored blob $key unparseable, replacing from backup',
          tag: 'Backup',
        );
      }
    }
    await store.write(key, _encodeSorted(importedList));
    return importedList.length;
  }

  String _encodeSorted(Iterable<Map<String, dynamic>> records) {
    final list = records.toList()
      ..sort(
        (a, b) => ((a['timestamp'] as int?) ?? 0).compareTo(
          (b['timestamp'] as int?) ?? 0,
        ),
      );
    return jsonEncode(list);
  }

  /// Contacts merge: by public key; existing (device-synced) records win on
  /// all fields EXCEPT user-owned ones they lack, which the backup fills in.
  /// Contacts present only in the backup are NOT resurrected — if the device
  /// no longer knows them, their messages can stay dormant in the store until
  /// the contact is re-added.
  Future<int> _mergeContactsBlob(
    BlobStore store,
    String key,
    String imported,
  ) async {
    final importedList = _decodeRecordList(imported);
    final existing = await store.read(key);
    if (existing == null || existing.isEmpty) {
      await store.write(key, imported);
      return 0; // contact list itself was device-owned; nothing "restored"
    }
    final existingList = _decodeRecordList(existing);

    final byKey = <String, Map<String, dynamic>>{};
    for (final record in existingList) {
      final pk = record['publicKey'];
      if (pk is String) byKey[pk] = record;
    }
    var restored = 0;
    for (final record in importedList) {
      final pk = record['publicKey'];
      if (pk is! String) continue;
      final live = byKey[pk];
      if (live == null) continue;
      for (final field in _userOwnedContactFields) {
        final liveValue = live[field];
        final backupValue = record[field];
        if ((liveValue == null || liveValue == '') &&
            backupValue != null &&
            backupValue != '') {
          live[field] = backupValue;
          restored++;
        }
      }
    }
    await store.write(key, jsonEncode(existingList));
    return restored;
  }

  List<Map<String, dynamic>> _decodeRecordList(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! List) {
      throw const FormatException('expected a JSON array of records');
    }
    return decoded
        .map((e) => e as Map<String, dynamic>)
        .toList(growable: false);
  }

  /// Identity for merge-dedupe, matching MessageStore/ChannelMessageStore
  /// merge keys: messageId when present, else a sender+timestamp+text
  /// composite. Channel records carry senderName instead of senderKey.
  @visibleForTesting
  static String recordIdentity(Map<String, dynamic> record) {
    final messageId = record['messageId'];
    if (messageId is String && messageId.isNotEmpty) {
      return 'id:$messageId';
    }
    final sender =
        record['senderKey'] ??
        record['senderName'] ??
        record['senderKeyHex'] ??
        '';
    return 'x:$sender:${record['timestamp']}:${record['text']}';
  }
}
