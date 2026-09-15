import '../connector/meshcore_protocol.dart';
import '../models/contact.dart';
import 'app_localizations.dart';

/// UI-level localization helpers for [Contact].
///
/// Kept out of the model layer so `Contact` does not depend on
/// `AppLocalizations`. Use these from widgets/screens; for logs and
/// non-UI export use `Contact.typeLabelRaw`.
extension ContactLocalization on Contact {
  String typeLabel(AppLocalizations l10n) {
    switch (type) {
      case advTypeChat:
        return l10n.contact_typeChat;
      case advTypeRepeater:
        return l10n.contact_typeRepeater;
      case advTypeRoom:
        return l10n.contact_typeRoom;
      case advTypeSensor:
        return l10n.contact_typeSensor;
      default:
        return l10n.contact_typeUnknown;
    }
  }

  String pathLabel(AppLocalizations l10n) {
    if (pathOverride != null) {
      if (pathOverride! < 0) return l10n.chat_floodForced;
      if (pathOverride == 0) return l10n.chat_directForced;
      return l10n.chat_hopsForced(pathOverride!);
    }
    if (pathLength < 0) return l10n.channelPath_floodPath;
    if (pathLength == 0) return _withQuality(l10n.chat_direct);
    return _withQuality(l10n.chat_hopsCount(pathLength));
  }

  /// Appends measured route quality (g33k3r firmware dialect, v90+) when the
  /// device reported it. '⇄' marks an alternate route being available.
  String _withQuality(String base) {
    final db = pathQualityDb;
    if (db == null) return base;
    final q = '${db >= 0 ? '+' : ''}${db.toStringAsFixed(1)} dB';
    return (hasAltPath == true) ? '$base · $q ⇄' : '$base · $q';
  }
}
