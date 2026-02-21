package com.lifelens.app

import android.view.KeyEvent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity: FlutterActivity() {
    private val CHANNEL = "com.lifelens.app/volumebutton"
    
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { _, _ -> }
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
        MethodChannel(flutterEngine!!.dartExecutor.binaryMessenger, CHANNEL)
            .invokeMethod(method, null)
    }
}
