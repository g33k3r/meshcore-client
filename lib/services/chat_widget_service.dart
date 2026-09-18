import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:home_widget/home_widget.dart';

import '../connector/meshcore_connector.dart';
import '../models/contact.dart';
import '../models/message.dart';
import '../storage/message_store.dart';
import '../storage/prefs_manager.dart';
import '../utils/app_logger.dart';
import '../utils/platform_info.dart';

/// Android home-screen chat widget.
///
/// Shows the latest active chat: contact display name, last message, time,
/// unread badge. Tap opens that chat via a geekcore deep-link URI.
///
/// v1 honesty: data is written while the app runs (messages only arrive while
/// connected anyway); Android's updatePeriodMillis refreshes the view, it does
/// not fetch new data on its own.
class ChatWidgetService {
  // Fully qualified: the plugin resolves simple names against the
  // applicationId (app.offband.meshcore), but the Kotlin provider lives in
  // the build namespace (com.meshcore.meshcore_open) — simple names
  // ClassNotFound and the update broadcast never fires.
  static const String _androidWidgetQualified =
      'com.meshcore.meshcore_open.ChatWidgetProvider';
  static const String _uriScheme = 'geekcore';
  static const String _uriHost = 'chat';

  final MeshCoreConnector _connector;
  final MessageStore _messageStore;
  final bool enabled;

  Timer? _debounce;
  StreamSubscription<Uri?>? _clickSub;
  Timer? _periodic;

  /// Emits the chat key (pubKeyHex) to open when the widget is tapped.
  final ValueNotifier<String?> pendingChatKey = ValueNotifier<String?>(null);

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

  static const String _pinnedKeyPref = 'chat_widget_pinned_contact';

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

  /// Pure: the contact the widget should show — the pinned one when set (and
  /// still present/active), else the latest-activity contact.
  static Contact? pickContact(
    List<Contact> contacts, {
    String? pinnedKeyHex,
  }) {
    if (pinnedKeyHex != null && pinnedKeyHex.isNotEmpty) {
      for (final c in contacts) {
        if (c.isActive && c.publicKeyHex == pinnedKeyHex) return c;
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
  }

  void _onConnectorChanged() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 700), () => update());
  }

  Future<void> update() async {
    if (!enabled) return;
    try {
      final contact = pickContact(
        _connector.contacts,
        pinnedKeyHex: pinnedContactKey(),
      );
      if (contact == null) return;
      final messages = await _messageStore.loadMessages(contact.publicKeyHex);
      final data = format(
        contact,
        messages,
        _connector.getUnreadCountForContactKey(contact.publicKeyHex),
      );
      await Future.wait([
        HomeWidget.saveWidgetData<String>('title', data.title),
        HomeWidget.saveWidgetData<String>('message', data.message),
        HomeWidget.saveWidgetData<int>('when', data.time.millisecondsSinceEpoch),
        HomeWidget.saveWidgetData<int>('unread', data.unread),
        HomeWidget.saveWidgetData<String>(
          'uri',
          '$_uriScheme://$_uriHost/${data.chatKeyHex}',
        ),
      ]);
      await HomeWidget.updateWidget(qualifiedAndroidName: _androidWidgetQualified);
    } catch (e) {
      appLogger.warn('ChatWidget update failed: $e', tag: 'ChatWidget');
    }
  }

  /// Cold-start path: the OS launched us via the widget tap.
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
    if (uri.scheme != _uriScheme || uri.host != _uriHost) return;
    final key = uri.pathSegments.isEmpty ? '' : uri.pathSegments.first;
    if (key.isEmpty) return;
    pendingChatKey.value = key;
  }
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
