package com.percive.app

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.os.Build
import android.view.KeyEvent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity: FlutterActivity() {
    private val CHANNEL = "com.percive.app/volumebutton"
    private lateinit var volumeButtonChannel: MethodChannel
    
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        
        createNotificationChannel()
        
        // Create channel once and reuse it
        volumeButtonChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        volumeButtonChannel.setMethodCallHandler { _, result -> 
            result.notImplemented()
        }
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channelId = "help_requests"
            val channelName = "Help Requests"
            val channelDescription = "Notifications for incoming volunteer requests"
            val importance = NotificationManager.IMPORTANCE_HIGH
            val channel = NotificationChannel(channelId, channelName, importance).apply {
                description = channelDescription
                enableLights(true)
                enableVibration(true)
            }
            val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            notificationManager.createNotificationChannel(channel)
        }
    }
    
    override fun onKeyDown(keyCode: Int, event: KeyEvent?): Boolean {
        return when (keyCode) {
            KeyEvent.KEYCODE_VOLUME_UP -> {
                sendVolumeButtonEvent("onVolumeUp")
                true
            }
            KeyEvent.KEYCODE_VOLUME_DOWN -> {
                sendVolumeButtonEvent("onVolumeDown")
                true
            }
            else -> super.onKeyDown(keyCode, event)
        }
    }
    
    private fun sendVolumeButtonEvent(method: String) {
        volumeButtonChannel.invokeMethod(method, null)
    }
}
