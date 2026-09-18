import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../connector/meshcore_connector.dart';
import '../services/chat_widget_service.dart';

/// Picker for pinning a home-screen widget instance to a conversation.
/// Reached by tapping an unconfigured widget (geekcore://widget-pick/...).
class WidgetPickScreen extends StatelessWidget {
  final WidgetPickRequest request;

  const WidgetPickScreen({super.key, required this.request});

  @override
  Widget build(BuildContext context) {
    final connector = context.read<MeshCoreConnector>();
    final isDm = request.type == 'dm';

    final contacts =
        connector.contacts.where((c) => c.isActive).toList()
          ..sort((a, b) => b.lastMessageAt.compareTo(a.lastMessageAt));
    final channels = connector.channels.where((c) => !c.isEmpty).toList();

    return Scaffold(
      appBar: AppBar(
        title: Text(
          isDm ? 'Widget: choose a chat' : 'Widget: choose a group',
        ),
      ),
      body: isDm
          ? (contacts.isEmpty
                ? const _EmptyHint(text: 'No contacts yet.')
                : ListView.builder(
                    itemCount: contacts.length,
                    itemBuilder: (context, i) {
                      final c = contacts[i];
                      return ListTile(
                        leading: CircleAvatar(child: Text(c.displayName.isEmpty ? '?' : c.displayName[0])),
                        title: Text(c.displayName, maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(
                          c.shortPubKeyHex,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 11),
                        ),
                        onTap: () => _pickDm(context, c.publicKeyHex),
                      );
                    },
                  ))
          : (channels.isEmpty
                ? const _EmptyHint(text: 'No groups yet.')
                : ListView.builder(
                    itemCount: channels.length,
                    itemBuilder: (context, i) {
                      final ch = channels[i];
                      return ListTile(
                        leading: const CircleAvatar(child: Icon(Icons.tag)),
                        title: Text(ch.name.isEmpty ? 'Group ${ch.index}' : ch.name),
                        onTap: () => _pickChannel(context, ch.index),
                      );
                    },
                  )),
    );
  }

  Future<void> _pickDm(BuildContext context, String pubkeyHex) async {
    await ChatWidgetService.setDmTarget(request.widgetId, pubkeyHex);
    if (context.mounted) Navigator.of(context).pop();
  }

  Future<void> _pickChannel(BuildContext context, int channelIndex) async {
    await ChatWidgetService.setChannelTarget(request.widgetId, channelIndex);
    if (context.mounted) Navigator.of(context).pop();
  }
}

class _EmptyHint extends StatelessWidget {
  final String text;
  const _EmptyHint({required this.text});

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Text(text, style: Theme.of(context).textTheme.bodyMedium),
    ),
  );
}
