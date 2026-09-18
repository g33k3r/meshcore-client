import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:home_widget/home_widget.dart';

import '../connector/meshcore_connector.dart';
import '../models/channel_message.dart';
import '../models/channel.dart';
import '../models/contact.dart';
import '../models/message.dart';
import '../storage/message_store.dart';
import '../storage/prefs_manager.dart';
import '../utils/app_logger.dart';
import '../utils/platform_info.dart';

/// Android home-screen widgets: one DM widget type, one Group widget type.
/// Each placed INSTANCE is pinned to one conversation (chosen via the
/// in-app picker reached by tapping an unconfigured widget).
///
/// Data flow: this service writes per-instance values via the home_widget
/// plugin (title/id, message/id, when/id, unread/id, uri/id); the
/// Kotlin provider renders them. Unconfigured instances show a
/// "tap to choose" placeholder whose uri is a geekcore widget-pick link.
///
/// Legacy: a globally-pinned contact (contact settings toggle) still drives
/// any DM instance that has no explicit target.
///
/// v1 honesty: data is written while the app runs; updatePeriodMillis
/// re-renders, it does not fetch.
class ChatWidgetService {
  /// Fully qualified: the plugin resolves simple names against the
  /// applicationId (app.offband.meshcore), but the Kotlin provider lives in
  /// the build namespace (com.meshcore.meshcore_open) — simple names
  /// ClassNotFound and the update broadcast never fires.
  static const String _dmQualified =
      'com.meshcore.meshcore_open.ChatWidgetProvider';
  static const String _channelQualified =
      'com.meshcore.meshcore_open.ChannelWidgetProvider';

  static const String _uriScheme = 'geekcore';
  static const String _pinnedKeyPref = 'chat_widget_pinned_contact';
  static const String _dmTargetsPref = 'chat_widget_dm_targets'; // {id: hex}
  static const String _chTargetsPref = 'chat_widget_channel_targets'; // {id: idx}

  final MeshCoreConnector _connector;
  final MessageStore _messageStore;
  final bool enabled;

  Timer? _debounce;
  StreamSubscription<Uri?>? _clickSub;
  Timer? _periodic;

  /// Emits the chat key (pubKeyHex) to open when a widget is tapped, or a
  /// pick request (type, widgetId) for unconfigured widgets.
  final ValueNotifier<String?> pendingChatKey = ValueNotifier<String?>(null);
  final ValueNotifier<WidgetPickRequest?> pendingPick =
      ValueNotifier<WidgetPickRequest?>(null);

  /// App-singleton locator (one service per app run; set in constructor).
  static ChatWidgetService? instance;

  ChatWidgetService({
    required MeshCoreConnector connector,
    required MessageStore messageStore,
    bool enabled = true,
  }) : _connector = connector,
       _messageStore = messageStore,
       enabled = enabled && PlatformInfo.isAndroid && !kIsWeb {
    instance = this;
  }

  // ── target registries ────────────────────────────────────────────

  static Map<int, String> dmTargets() => _readMap(_dmTargetsPref);
  static Map<int, int> channelTargets() => _readMap(_chTargetsPref)
      .map((k, v) => MapEntry(k, int.tryParse(v) ?? -1));

  static Future<void> setDmTarget(int widgetId, String? pubkeyHex) async =>
      _writeMap(_dmTargetsPref, widgetId, pubkeyHex);

  static Future<void> setChannelTarget(int widgetId, int? channelIndex) async =>
      _writeMap(
        _chTargetsPref,
        widgetId,
        channelIndex?.toString(),
      );

  static Map<int, String> _readMap(String pref) {
    final raw = PrefsManager.instance.getString(pref);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      return decoded.map(
        (k, v) => MapEntry(int.tryParse(k) ?? -1, v?.toString() ?? ''),
      )..removeWhere((k, _) => k < 0);
    } catch (_) {
      return {};
    }
  }

  static Future<void> _writeMap(String pref, int widgetId, String? value) async {
    final map = _readMap(pref);
    if (value == null || value.isEmpty) {
      map.remove(widgetId);
    } else {
      map[widgetId] = value;
    }
    await PrefsManager.instance.setString(pref, jsonEncode(map));
    await instance?.update();
  }

  /// The pubkey hex pinned to the home-screen widget (null = follow latest).
  static String? pinnedContactKey() =>
      PrefsManager.instance.getString(_pinnedKeyPref);

  static Future<void> setPinnedContact(String? keyHex) async {
    if (keyHex == null) {
      await PrefsManager.instance.remove(_pinnedKeyPref);
    } else {
      await PrefsManager.instance.setString(_pinnedKeyPref, keyHex);
    }
  }

  // ── pure data prep ───────────────────────────────────────────────

  /// Pure: the DM widget's contact for [targetHex] — explicit target first,
  /// then the legacy global pin, then latest activity. Null = placeholder.
  static Contact? pickContact(
    List<Contact> contacts, {
    String? pinnedKeyHex,
    String? targetHex,
  }) {
    for (final source in [targetHex, pinnedKeyHex]) {
      if (source != null && source.isNotEmpty) {
        for (final c in contacts) {
          if (c.isActive && c.publicKeyHex == source) return c;
        }
      }
    }
    Contact? latest;
    for (final c in contacts) {
      if (!c.isActive) continue;
      if (latest == null || c.lastMessageAt.isAfter(latest.lastMessageAt)) {
        latest = c;
      }
    }
    return latest;
  }

  /// Pure: the widget lines for a contact + its message history.
  static ChatWidgetData format(
    Contact contact,
    List<Message> messages,
    int unread,
  ) {
    String message = 'No messages yet';
    DateTime at = contact.lastMessageAt;
    if (messages.isNotEmpty) {
      final m = messages.last;
      message = (m.isOutgoing ? 'You: ' : '') + m.text;
      at = m.timestamp;
    }
    return ChatWidgetData(
      title: contact.displayName,
      message: message,
      time: at,
      unread: unread,
      chatKeyHex: contact.publicKeyHex,
    );
  }

  /// Pure: the widget lines for a group channel + its history.
  static ChatWidgetData formatChannel(
    String channelName,
    List<ChannelMessage> messages,
    int unread,
    int channelIndex,
  ) {
    String message = 'No messages yet';
    DateTime at = DateTime.fromMillisecondsSinceEpoch(0);
    if (messages.isNotEmpty) {
      final m = messages.last;
      message = m.isOutgoing
          ? 'You: ${m.text}'
          : '${m.senderName.isEmpty ? '?' : m.senderName}: ${m.text}';
      at = m.timestamp;
    }
    return ChatWidgetData(
      title: channelName.isEmpty ? 'Group $channelIndex' : channelName,
      message: message,
      time: at,
      unread: unread,
      chatKeyHex: 'channel:$channelIndex',
    );
  }

  // ── lifecycle ────────────────────────────────────────────────────

  Future<void> start() async {
    if (!enabled) return;
    try {
      await HomeWidget.setAppGroupId('app.offband.meshcore');
    } catch (_) {/* android: no-op */}
    _connector.addListener(_onConnectorChanged);
    _clickSub = HomeWidget.widgetClicked.listen(_handleClick);
    unawaited(checkLaunch());
    _periodic = Timer.periodic(const Duration(seconds: 60), (_) => update());
    unawaited(update());
  }

  void dispose() {
    _debounce?.cancel();
    _periodic?.cancel();
    _clickSub?.cancel();
    _connector.removeListener(_onConnectorChanged);
    instance = null;
  }

  void _onConnectorChanged() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 700), () => update());
  }

  Future<void> update() async {
    if (!enabled) return;
    try {
      final writes = <Future<bool?>>[];

      // DM instances
      final dm = dmTargets();
      final dmIds = dm.keys.toList();
      for (final id in dmIds) {
        final contact = pickContact(
          _connector.contacts,
          pinnedKeyHex: pinnedContactKey(),
          targetHex: dm[id],
        );
        if (contact == null) continue;
        final messages = await _messageStore.loadMessages(
          contact.publicKeyHex,
        );
        final data = format(
          contact,
          messages,
          _connector.getUnreadCountForContactKey(contact.publicKeyHex),
        );
        writes.addAll(_saveInstance(id, data, 'chat/${data.chatKeyHex}'));
      }

      // Group instances
      final ch = channelTargets();
      for (final id in ch.keys) {
        final idx = ch[id]!;
        Channel? channel;
        for (final c in _connector.channels) {
          if (c.index == idx) {
            channel = c;
            break;
          }
        }
        final messages = await _connector.channelMessageStore
            .loadChannelMessages(idx);
        final data = formatChannel(
          channel?.name ?? '',
          messages,
          _connector.getUnreadCountForChannelIndex(idx),
          idx,
        );
        writes.addAll(_saveInstance(id, data, 'channel/$idx'));
      }

      await Future.wait(writes);
      await Future.wait([
        HomeWidget.updateWidget(qualifiedAndroidName: _dmQualified),
        HomeWidget.updateWidget(qualifiedAndroidName: _channelQualified),
      ]);
    } catch (e) {
      appLogger.warn('ChatWidget update failed: $e', tag: 'ChatWidget');
    }
  }

  List<Future<bool?>> _saveInstance(
    int id,
    ChatWidgetData data,
    String uriPath,
  ) {
    return [
      HomeWidget.saveWidgetData<String>('title_$id', data.title),
      HomeWidget.saveWidgetData<String>('message_$id', data.message),
      HomeWidget.saveWidgetData<int>('when_$id', data.time.millisecondsSinceEpoch),
      HomeWidget.saveWidgetData<int>('unread_$id', data.unread),
      HomeWidget.saveWidgetData<String>('uri_$id', '$_uriScheme://$uriPath'),
    ];
  }

  /// Cold-start path: the OS launched us via a widget tap.
  Future<void> checkLaunch() async {
    if (!enabled) return;
    try {
      final uri = await HomeWidget.initiallyLaunchedFromHomeWidget();
      _handleUri(uri);
    } catch (_) {}
  }

  void _handleClick(Uri? uri) => _handleUri(uri);

  void _handleUri(Uri? uri) {
    if (uri == null) return;
    if (uri.scheme != _uriScheme) return;
    if (uri.host == 'chat') {
      final key = uri.pathSegments.isEmpty ? '' : uri.pathSegments.first;
      if (key.isNotEmpty) pendingChatKey.value = key;
    } else if (uri.host == 'channel') {
      final idx = uri.pathSegments.isEmpty ? '' : uri.pathSegments.first;
      final i = int.tryParse(idx);
      if (i != null) {
        pendingChatKey.value = 'channel:$i';
      }
    } else if (uri.host == 'widget-pick') {
      final segs = uri.pathSegments;
      if (segs.length >= 2) {
        final type = segs[0];
        final id = int.tryParse(segs[1]);
        if (id != null && (type == 'dm' || type == 'channel')) {
          pendingPick.value = WidgetPickRequest(type: type, widgetId: id);
        }
      }
    }
  }
}

class WidgetPickRequest {
  final String type; // 'dm' | 'channel'
  final int widgetId;

  WidgetPickRequest({required this.type, required this.widgetId});
}

class ChatWidgetData {
  final String title;
  final String message;
  final DateTime time;
  final int unread;
  final String chatKeyHex;

  ChatWidgetData({
    required this.title,
    required this.message,
    required this.time,
    required this.unread,
    required this.chatKeyHex,
  });
}
