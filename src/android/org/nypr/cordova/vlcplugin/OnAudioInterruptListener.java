package org.nypr.cordova.vlcplugin;

public interface OnAudioInterruptListener {

    enum INTERRUPT_TYPE {
        INTERRUPT_PHONE,
        INTERRUPT_HEADSET,
        INTERRUPT_OTHER_APP
    }

    void onAudioInterruptDetected(INTERRUPT_TYPE type, boolean trackInterrupt);

    void onAudioInterruptCompleted(INTERRUPT_TYPE type, boolean restart);
}
