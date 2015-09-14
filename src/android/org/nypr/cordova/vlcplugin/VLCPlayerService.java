package org.nypr.cordova.vlcplugin;

import android.app.Activity;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.net.Uri;
import android.os.Binder;
import android.os.Bundle;
import android.os.IBinder;
import android.support.v4.app.NotificationCompat;
import android.util.Log;
import android.widget.RemoteViews;

import org.apache.cordova.LOG;
import org.json.JSONException;
import org.json.JSONObject;
import org.nypr.android.R;
import org.videolan.libvlc.LibVLC;
import org.videolan.libvlc.Media;
import org.videolan.libvlc.MediaPlayer;

import java.io.IOException;
import java.util.HashSet;


public class VLCPlayerService extends Service implements MediaPlayer.EventListener {

    private static final String LOG_TAG = "VLCPlayerService";
    private static final int NOTIFICATION_ID = 100;

    public class LocalBinder extends Binder {

        public VLCPlayerService getService() {
            return VLCPlayerService.this;
        }

    }

    private LocalBinder binder = new LocalBinder();

    @Override
    public IBinder onBind(Intent intent) {
        Log.d(LOG_TAG, "Service bound");
        return binder;
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        int i = super.onStartCommand(intent, flags, startId);

        if (intent == null) {
            mNotificationManager.cancel(NOTIFICATION_ID);
            this.stopSelf();
        }
        return i;
    }

    @Override
    public void onCreate() {
        super.onCreate();

        Log.d(LOG_TAG, "Service created");

        mPendingInterrupts = new HashSet<OnAudioInterruptListener.INTERRUPT_TYPE>();

        libVLC = new LibVLC();
        mediaPlayer = new MediaPlayer(libVLC);
        mediaPlayer.setEventListener(this);

        Log.d(LOG_TAG, "Started NYPR Audio Player");

        remoteViews = new RemoteViews(getPackageName(), R.layout.nypr_ph_hc_notification);
        mNotificationManager = (NotificationManager) getSystemService(Context.NOTIFICATION_SERVICE);
    }

    @Override
    public boolean onUnbind(Intent intent) {
        boolean b = super.onUnbind(intent);
        Log.d(LOG_TAG, "Unbinding Service");
        mNotificationManager.cancel(NOTIFICATION_ID);
        this.stopSelf();
        return b;
    }

    @Override
    public void onDestroy() {
        mediaPlayer.stop();
        libVLC.release();

        super.onDestroy();
        Log.d(LOG_TAG, "Service Destroyed");
    }

    protected HashSet<OnAudioInterruptListener.INTERRUPT_TYPE> mPendingInterrupts;
    protected OnAudioStateUpdatedListenerVLC mListener;
    protected STATE mLastStateFired;
    private LibVLC libVLC;
    private MediaPlayer mediaPlayer;
    private Media currentlyPlaying;
    private MediaPlayer.Event previousEvent;
    private RemoteViews remoteViews;
    public Activity cordovaActivity;
    NotificationManager mNotificationManager;

    private int currentStateType;

    // AudioPlayer states
    public enum STATE {
        MEDIA_NONE,
        MEDIA_STARTING,
        MEDIA_RUNNING,
        MEDIA_PAUSED,
        MEDIA_STOPPED,
        MEDIA_LOADING,
        MEDIA_COMPLETED
    }

    public void setAudioStateListener(OnAudioStateUpdatedListenerVLC mListener) {
        this.mListener = mListener;
    }

    public JSONObject checkForExistingAudio() throws JSONException {
        Log.d(LOG_TAG, "On startup, checking service for pre-existing audio...");
        JSONObject json = null;


        if (mediaPlayer.isPlaying()) {
            Media media = mediaPlayer.getMedia();
            if (media != null) {
                json = new JSONObject();
                json.put("duration", media.getDuration());
                json.put("state", media.getState());
                json.put("uri", media.getUri());
            }
        }
        return json;
    }

    public void onAudioStreamingError(int reason) {
        mListener.onAudioStreamingError(reason);
    }

    public boolean isPlaying() {
        return mediaPlayer != null && mediaPlayer.isPlaying();
    }

    public void setAudioInfo(String title, String artist, String url) {
            /*
             * TODO -- figure out a way to update notification data mid-stream
			 *
			Bundle bundle = new Bundle();
			bundle.putString("title", title);
			bundle.putString("artist", artist);
			bundle.putParcelable("uri", Uri.parse(url));
			mPlaying = Songs.fromBundle(bundle);*/

        refreshAudioInfo();
    }

    public void refreshAudioInfo() {
        if (mediaPlayer != null) {
            //Log.d(LOG_TAG, "NOT REFRESHING AUDIO INFO");
            /*
            mHater.setTitle(mPlaying.getTitle());
			mHater.setArtist(mPlaying.getArtist());
			//if(url!=null){
			//	Uri uri=Uri.parse(url);
				mHater.setAlbumArt(mPlaying.getAlbumArt());
			//
			 */

//            mediaPlayer.setTitle(currentlyPlaying.getMeta(Media.Meta.Title));
        }
    }

    public void startPlaying(String file, String title, String artist, String url, int position, JSONObject audioJson, boolean isStream) throws IOException {
        Log.d(LOG_TAG, "Starting Audio--" + file);

        // handle m3u file
        if (file.toUpperCase().endsWith("M3U")) {
            Log.d(LOG_TAG, "M3U found, parsing...");
            String parsed = "";//ParserM3UToURL.parse(file);
            if (parsed != null) {
                file = parsed;
                Log.d(LOG_TAG, "Using parsed url--" + file);
            } else {
                Log.d(LOG_TAG, "No stream found in M3U");
            }
        }

        // create a Uri object for audio
        Uri uri = Uri.parse(file);

        // create a Uri object of artwork
        Uri artworkUri = null;
        if (url != null) {
            artworkUri = Uri.parse(url);
        }

        // create a Bundle, used to create Song
        Bundle bundle = new Bundle();
        bundle.putString("title", title);
        bundle.putString("artist", artist);
        if (artworkUri != null) {
            bundle.putParcelable("album_art", artworkUri);
        }
        bundle.putParcelable("uri", uri);
        Bundle extra = new Bundle();
        extra.putString("audioJson", audioJson.toString()); // store in bundle as a string
        extra.putBoolean("isStream", isStream);
        bundle.putBundle("extra", extra);

        // create the Song object
        // Song song = Songs.fromBundle(bundle);
        Media media = new Media(libVLC, uri);

        int estimatedDuration = 0;
        try {
            estimatedDuration = audioJson.getInt("estimated_duration");
        } catch (JSONException e) {
            Log.e(LOG_TAG, e.getMessage());
        }
        float pct = position / (float) estimatedDuration;

        remoteViews.setTextViewText(R.id.zzz_ph_notification_title, title);
        remoteViews.setTextViewText(R.id.zzz_ph_notification_text, artist);

        PendingIntent closeAppIntent = PendingIntent.getBroadcast(this, 1, new Intent(this, NotificationReceiver.class), 0);

        remoteViews.setOnClickPendingIntent(R.id.zzz_ph_stop_button, closeAppIntent);

        PendingIntent pendingIntent = PendingIntent.getActivity(this, 0, new Intent(this, cordovaActivity.getClass()), PendingIntent.FLAG_UPDATE_CURRENT);

        NotificationCompat.Builder mBuilder = new NotificationCompat
                .Builder(this)
                .setSmallIcon(R.drawable.zzz_ph_ic_notification)
                .setContent(remoteViews)
                .setOngoing(true)
                .setContentIntent(pendingIntent);


        NotificationManager mNotificationManager = (NotificationManager) getSystemService(Context.NOTIFICATION_SERVICE);
        // mId allows you to update the notification later on.
        mNotificationManager.notify(NOTIFICATION_ID, mBuilder.build());

        // play the Song
        startPlaying(media, pct);
    }

    protected void startPlaying(Media media, float position) throws IOException {
        // TODO - perform an inventory of interrupts

        Log.d(LOG_TAG, "Starting Stream from Song--" + media.getUri().toString());

        if (mPendingInterrupts.size() == 0) {
            // if stream is started when an audio interrupt(s) exists,
            // don't play, store new stream for when interrupt(s) go away
            // stream will be (re)started by resumeAudio


            Media currentMedia = mediaPlayer.getMedia();

            if (currentMedia == null || !currentMedia.getUri().toString().equals(media.getUri().toString())) {
                mediaPlayer.setMedia(media);
                mediaPlayer.play();
                mediaPlayer.setPosition(position);
            } else {
                mediaPlayer.play();
            }
        }
    }

    public void pausePlaying() {
        // make sure audio is playing
        // check queue position as a secondary check -- an edge condition exists where if a song completes, and pause is called afterward, a crash occurs
        if (mediaPlayer.isPlaying()) {
            mediaPlayer.pause();

        } else {
//            Log.d(LOG_TAG, "No audio playing -- skipping pause. isPlaying=" + mediaPlayer.isPlaying() + "; getQueuePosition()=" + mHater.getQueuePosition());
        }
    }

    public void playerInterrupted() {
        Log.d(LOG_TAG, "Firing MEDIA_PAUSED on stream finish on error");
//        this.fireTransientState(STATE.MEDIA_PAUSED);
    }

    public void seekAudio(int interval) {
        Log.d(LOG_TAG, "Seek Audio. Interval: " + interval);
        if (mediaPlayer.getLength() > 0) {
            if (isPlaying()) {
                float currentPosition = mediaPlayer.getPosition(); // this is a percentage
                int newPosition = (int) ((currentPosition * mediaPlayer.getLength()) + interval);
                Log.d(LOG_TAG, "New Position: " + newPosition);
                if (mediaPlayer.isSeekable()) {
                    long duration = mediaPlayer.getMedia().getDuration();
                    float percentage = newPosition / (float) duration;
                    mediaPlayer.setPosition(percentage);
                }
            } else {
                Log.d(LOG_TAG, "Not currently playing, so not seeking");
            }
        } else {
            Log.d(LOG_TAG, "Seek not available.");
        }
    }

    public void seekToAudio(int pos) {
        Log.d(LOG_TAG, "Seek Audio. Position: " + pos);
        if (mediaPlayer.getMedia().getDuration() > 0) {
            if (isPlaying() && mediaPlayer.isSeekable()) {
                float duration = (float) getDuration();
                float pct = pos / duration;
                Log.d(LOG_TAG, "PCT = " + pos + " / " + duration + " = " + pct);

                mediaPlayer.setPosition(pct);
            } else {
                Log.d(LOG_TAG, "Not currently playing, so not seeking");
            }
        } else {
            Log.d(LOG_TAG, "Seek not available.");
        }
    }

    public void stopPlaying() {
        Log.d(LOG_TAG, "Stopping Stream");
        if (mediaPlayer != null) {
            if (mediaPlayer.isPlaying()/* || mediaPlayer.getPlayerState() == 0*/) {
                mediaPlayer.stop();
            }
        }
        // clear interrupts
        mPendingInterrupts.clear();
    }


    public void interruptAudio(OnAudioInterruptListener.INTERRUPT_TYPE type, boolean trackInterrupt) {
        // stop audio. store the fact that this interrupt is pending
        if (!mPendingInterrupts.contains(type) && mediaPlayer.isPlaying()) {
            Log.d(LOG_TAG, "Audio interrupted - stop audio - " + type);
            if (trackInterrupt) {
                // if tracked, don't allow stream resumption until interrupt goes away
                mPendingInterrupts.add(type);
                pausePlaying();
            } else {
                stopPlaying();
            }
        }
    }

    public void clearAudioInterrupt(OnAudioInterruptListener.INTERRUPT_TYPE type, boolean restart) throws IOException {
        if (mPendingInterrupts.contains(type)) {
            Log.d(LOG_TAG, "Audio interrupt over - " + type);

            // remove this interrupt
            mPendingInterrupts.remove(type);
            // make sure there are no other interrupts
            if (mPendingInterrupts.size() == 0) {
                if (restart) {
                    Log.d(LOG_TAG, "Audio interrupt over - restart audio - " + type);

                    startPlaying(currentlyPlaying, 0);
                }
            } else {
                Log.d(LOG_TAG, "Interrupts still pending");
            }
        }
    }

    public void fireAudioStateUpdated() {
        if (mListener != null && previousEvent != null) {
            mListener.onAudioStateUpdated(previousEvent);
        }
    }

    public int getDuration() {
        return (int) mediaPlayer.getMedia().getDuration();
    }

    public Activity getCordovaActivity() {
        return cordovaActivity;
    }

    public void setCordovaActivity(Activity cordovaActivity) {
        this.cordovaActivity = cordovaActivity;
    }

    @Override
    public void onEvent(MediaPlayer.Event event) {
        int stateType = event.type;

        if (stateType != currentStateType) {
            mListener.onAudioStateUpdated(event);
            currentStateType = stateType;
            previousEvent = event;

            Log.d(LOG_TAG, String.valueOf(currentStateType));
        }
    }
}
