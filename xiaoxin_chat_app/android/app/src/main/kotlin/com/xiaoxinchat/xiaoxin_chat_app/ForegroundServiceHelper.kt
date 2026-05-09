package com.xiaoxinchat.xiaoxin_chat_app

import android.content.Context
import android.content.Intent

class ForegroundServiceHelper {
    companion object {
        fun startForegroundService(context: Context) {
            val intent = Intent(context, WechatBotService::class.java)
            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }
        
        fun stopForegroundService(context: Context) {
            val intent = Intent(context, WechatBotService::class.java)
            context.stopService(intent)
        }
    }
}
