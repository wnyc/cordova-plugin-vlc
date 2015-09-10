package org.nypr.cordova.vlcplugin;

import android.content.Context;
import android.net.Uri;
import android.os.Bundle;
import android.os.Environment;
import android.util.Log;

import org.json.JSONException;
import org.json.JSONObject;
import org.nypr.cordova.vlcplugin.OnAudioInterruptListener;
import org.nypr.cordova.vlcplugin.OnAudioStateUpdatedListenerVLC;
import org.videolan.libvlc.LibVLC;
import org.videolan.libvlc.Media;
import org.videolan.libvlc.MediaPlayer;

import java.io.IOException;
import java.util.HashSet;

public class NYPRAudioPlayer implements MediaPlayer.EventListener {

    protected static final String LOG_TAG = "NYPRAudioPlayer";

    protected Context mContext;
    protected HashSet<OnAudioInterruptListener.INTERRUPT_TYPE> mPendingInterrupts;
    protected OnAudioStateUpdatedListenerVLC mListener;
    protected STATE mLastStateFired;
    private LibVLC libVLC;
    private MediaPlayer mediaPlayer;
    private Media currentlyPlaying;
    private MediaPlayer.Event previousEvent;
    private float position;

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

    public NYPRAudioPlayer(Context context, OnAudioStateUpdatedListenerVLC listener) {
        mContext = context;
        mListener = listener;
        mPendingInterrupts = new HashSet<OnAudioInterruptListener.INTERRUPT_TYPE>();

        libVLC = new LibVLC();
        mediaPlayer = new MediaPlayer(libVLC);
        mediaPlayer.setEventListener(this);

        Log.d(LOG_TAG, "Started NYPR Audio Player");
    }

    public JSONObject checkForExistingAudio() throws JSONException {
        Log.d("LOG_TAG", "On startup, checking service for pre-existing audio...");
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
        // use mHater.isPlaying()/mHater.isLoading() -- test to make sure they work

        //return getState().equals(STATE.MEDIA_LOADING) || getState().equals(STATE.MEDIA_RUNNING) || getState().equals(STATE.MEDIA_PAUSED) || getState().equals(STATE.MEDIA_STARTING);

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

        // play the Song
        startPlaying(media, position);
    }

    protected void startPlaying(Media media, int position) throws IOException {
        // TODO - perform an inventory of interrupts

        Log.d(LOG_TAG, "Starting Stream from Song--" + media.getUri().toString());

        if (mPendingInterrupts.size() == 0) {
            // if stream is started when an audio interrupt(s) exists,
            // don't play, store new stream for when interrupt(s) go away
            // stream will be (re)started by resumeAudio

            mediaPlayer.setMedia(media);
            mediaPlayer.play();
            mediaPlayer.setPosition(this.position);
        }
    }

    public void pausePlaying() {
        // make sure audio is playing
        // check queue position as a secondary check -- an edge condition exists where if a song completes, and pause is called afterward, a crash occurs
        if (mediaPlayer.isPlaying()) {
            mediaPlayer.pause();
            this.position = mediaPlayer.getPosition();
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
                float currentPosition = mediaPlayer.getPosition(); // ms
                int newPosition = (int) (currentPosition + (interval));
                Log.d(LOG_TAG, "Current/New Positions: " + currentPosition + "/" + newPosition);
                if (mediaPlayer.isSeekable()) {
                    float percentage = newPosition / mediaPlayer.getMedia().getDuration();
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
                mediaPlayer.setPosition(pos / (float) getDuration());
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
            if (mediaPlayer.isPlaying() || mediaPlayer.getPlayerState() == 0) {
                mediaPlayer.stop();
                position = 0;
            }
        }
//        mPlaying = null;
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
        return (int) mediaPlayer.getLength();
    }

    @Override
    public void onEvent(MediaPlayer.Event event) {
        int stateType = event.type;

        if (stateType != currentStateType) {
            mListener.onAudioStateUpdated(event);
            currentStateType = stateType;
            previousEvent = event;

            Log.d("Event", String.valueOf(currentStateType));
        }
    }
}
