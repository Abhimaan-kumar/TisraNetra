package com.lifelens.app

import android.view.KeyEvent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity: FlutterActivity() {
    private val CHANNEL = "com.lifelens.app/volumebutton"
    private lateinit var volumeButtonChannel: MethodChannel
    
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        
        // Create channel once and reuse it
        volumeButtonChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        volumeButtonChannel.setMethodCallHandler { _, result -> 
            result.notImplemented()
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
