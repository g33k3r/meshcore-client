package com.meshcore.meshcore_open

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.widget.RemoteViews
import java.text.DateFormat
import java.util.Date

/**
 * GeekCore home-screen widget base (fork feature).
 *
 * Each placed widget instance is pinned to one conversation. Flutter
 * (ChatWidgetService) writes per-instance data via the home_widget plugin's
 * SharedPreferences ("HomeWidgetPreferences"): title_<id>, message_<id>,
 * when_<id>, unread_<id>, uri_<id>. An unconfigured instance renders a
 * "tap to choose" placeholder whose uri is a geekcore://widget-pick link.
 *
 * Tap always follows uri_<id>: either opening that conversation or opening
 * the picker for the still-unconfigured instance.
 */
abstract class GeekCoreWidgetBase : AppWidgetProvider() {

    companion object {
        private const val PREFS = "HomeWidgetPreferences"
    }

    /** Widget type for pick links: "dm" or "channel". */
    abstract val pickType: String

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray
    ) {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        for (id in appWidgetIds) {
            val views = buildViews(context, prefs, id)
            appWidgetManager.updateAppWidget(id, views)
        }
    }

    private fun buildViews(context: Context, prefs: android.content.SharedPreferences, id: Int): RemoteViews {
        val title = prefs.getString("title_$id", null)
        val configured = title != null
        val message = prefs.getString("message_$id", null)
            ?: "Tap to choose a conversation"
        val whenMs = prefs.getLong("when_$id", 0L)
        val unread = prefs.getInt("unread_$id", 0)
        val uriStr = prefs.getString("uri_$id", null)
            ?: "geekcore://widget-pick/$pickType/$id"

        val timeText = if (configured && whenMs > 0L) {
            DateFormat.getTimeInstance(DateFormat.SHORT).format(Date(whenMs))
        } else ""

        return RemoteViews(context.packageName, R.layout.chat_widget).apply {
            setTextViewText(R.id.widget_title, title ?: "GeekCore ${if (pickType == "dm") "Chat" else "Group"}")
            setTextViewText(R.id.widget_message, message)
            setTextViewText(R.id.widget_time, timeText)
            if (configured && unread > 0) {
                setTextViewText(R.id.widget_unread, if (unread > 99) "99+" else unread.toString())
                setViewVisibility(R.id.widget_unread, android.view.View.VISIBLE)
            } else {
                setViewVisibility(R.id.widget_unread, android.view.View.GONE)
            }

            val intent = Intent(Intent.ACTION_VIEW, Uri.parse(uriStr)).setPackage(context.packageName)
            val pending = PendingIntent.getActivity(
                context,
                id,
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            setOnClickPendingIntent(R.id.widget_root, pending)
        }
    }
}
