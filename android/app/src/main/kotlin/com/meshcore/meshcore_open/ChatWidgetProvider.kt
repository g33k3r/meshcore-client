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
 * Home-screen chat widget (fork feature).
 *
 * Reads the snapshot written by ChatWidgetService (Flutter, via the
 * home_widget plugin's SharedPreferences) and renders it. Tap opens the
 * chat via geekcore://chat/<pubKeyHex> (see MainActivity intent-filter).
 */
class ChatWidgetProvider : AppWidgetProvider() {

    companion object {
        private const val PREFS = "HomeWidgetPreferences"
    }

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray
    ) {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val title = prefs.getString("title", "GeekCore") ?: "GeekCore"
        val message = prefs.getString("message", "No messages yet") ?: "No messages yet"
        val whenMs = prefs.getLong("when", 0L)
        val unread = prefs.getInt("unread", 0)
        val uriStr = prefs.getString("uri", null)

        val timeText = if (whenMs > 0L) {
            val df = DateFormat.getTimeInstance(DateFormat.SHORT)
            df.format(Date(whenMs))
        } else ""

        for (id in appWidgetIds) {
            val views = RemoteViews(context.packageName, R.layout.chat_widget).apply {
                setTextViewText(R.id.widget_title, title)
                setTextViewText(R.id.widget_message, message)
                setTextViewText(R.id.widget_time, timeText)
                if (unread > 0) {
                    setTextViewText(R.id.widget_unread, if (unread > 99) "99+" else unread.toString())
                    setViewVisibility(R.id.widget_unread, android.view.View.VISIBLE)
                } else {
                    setViewVisibility(R.id.widget_unread, android.view.View.GONE)
                }

                // whole widget opens the chat
                val intent = if (uriStr != null) {
                    Intent(Intent.ACTION_VIEW, Uri.parse(uriStr)).setPackage(context.packageName)
                } else {
                    context.packageManager.getLaunchIntentForPackage(context.packageName)
                }
                if (intent != null) {
                    val pending = PendingIntent.getActivity(
                        context,
                        id,
                        intent,
                        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                    )
                    setOnClickPendingIntent(R.id.widget_root, pending)
                }
            }
            appWidgetManager.updateAppWidget(id, views)
        }
    }
}
