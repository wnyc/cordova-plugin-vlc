package org.nypr.cordova.playerhaterplugin;

import org.videolan.libvlc.MediaPlayer;

public interface OnAudioStateUpdatedListenerVLC {
    void onAudioStateUpdated(MediaPlayer.Event event);

    void onAudioProgressUpdated(int progress, int duration);

    void onAudioStreamingError(int reason);
}
