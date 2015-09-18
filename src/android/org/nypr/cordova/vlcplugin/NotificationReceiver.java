package org.nypr.cordova.vlcplugin;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.util.Log;

public class NotificationReceiver extends BroadcastReceiver {

    @Override
    public void onReceive(Context context, Intent intent) {
        Log.d("NotificationReceiver", "Broadcast received, closing service");
        context.stopService(new Intent(context, VLCPlayerService.class));
    }

}
