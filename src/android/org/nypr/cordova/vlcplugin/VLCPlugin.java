package org.nypr.cordova.vlcplugin;

import java.io.File;
import java.io.IOException;
import java.lang.reflect.Field;

import org.apache.cordova.CallbackContext;
import org.apache.cordova.CordovaInterface;
import org.apache.cordova.CordovaPlugin;
import org.apache.cordova.CordovaWebView;
import org.apache.cordova.PluginResult;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.ServiceConnection;
import android.net.ConnectivityManager;
import android.os.Environment;
import android.os.IBinder;
import android.os.RemoteException;
import android.util.Log;

import org.videolan.libvlc.MediaPlayer;

public class VLCPlugin extends CordovaPlugin implements OnAudioInterruptListener, OnAudioStateUpdatedListenerVLC {

    private static final String INIT = "init";
    private static final String PLAY_STREAM = "playstream";
    private static final String PLAY_REMOTE_FILE = "playremotefile";
    private static final String PLAY_FILE = "playfile";
    private static final String PAUSE = "pause";
    private static final String SEEK = "seek";
    private static final String SEEK_TO = "seekto";
    private static final String STOP = "stop";
    private static final String HARD_STOP = "hardStop";
    private static final String SET_AUDIO_INFO = "setaudioinfo";
    private static final String GET_AUDIO_STATE = "getaudiostate";


    protected static final String LOG_TAG = "VLCPlugin";
//    protected static CordovaWebView mCachedWebView = null;

    protected PhoneHandler mPhoneHandler = null;
    protected CallbackContext connectionCallbackContext;
    protected VLCPlayerService playerService;

    private enum CordovaMediaState {
        MEDIA_NONE,
        MEDIA_STARTING,
        MEDIA_RUNNING,
        MEDIA_PAUSED,
        MEDIA_STOPPED,
        MEDIA_LOADING,
        MEDIA_COMPLETED
    }

    private ServiceConnection playerServiceConnection = new ServiceConnection() {

        @Override
        public void onServiceConnected(ComponentName className,
                                       IBinder service) {
            // We've bound to AudioPlayerService, cast the IBinder and get service instance
            playerService = ((VLCPlayerService.LocalBinder) service).getService();
            playerService.setAudioStateListener(VLCPlugin.this);
            playerService.setCordovaActivity(cordova.getActivity());
        }

        @Override
        public void onServiceDisconnected(ComponentName arg0) {
            cordova.getActivity().finish();
        }
    };

    @Override
    public void initialize(CordovaInterface cordova, CordovaWebView webView) {
        Log.d(LOG_TAG, "VLC Plugin initialize");
        super.initialize(cordova, webView);

        if (mPhoneHandler == null) {
            mPhoneHandler = new PhoneHandler(this);
            mPhoneHandler.startListening(cordova.getActivity().getApplicationContext());
        }

        if (playerService == null) {
            Intent intent = new Intent(cordova.getActivity(), VLCPlayerService.class);
            cordova.getActivity().startService(intent);
            cordova.getActivity().bindService(intent, playerServiceConnection, 0);
            Log.d(LOG_TAG, "Service started");
        }

        this.connectionCallbackContext = null;

//        if (mCachedWebView != null) {
            // this is a hack to destroy the old web view if it exists, which happens when audio is playing, the main app activity is 'killed' but the audio keeps playing, and then the app is restarted.
            // performing the hack here instead of when the app activity is destroyed because the web view continues to function even though the activity is killed, so it will process javascript messages
            // from the plugin telling it that the track is complete, so it will move to the next track if necessary...
//            Log.d(LOG_TAG, "Found cached web view -- destroying...");
//            String summary = "<html><body>Clear out JS</body></html>";
//            mCachedWebView.loadData(summary, "text/html", null);
            // loadData doesn't exist as a method anymore!
 //       }
 //       mCachedWebView = webView;

        Log.d(LOG_TAG, "VLC Plugin initialized");
    }

    @Override
    public boolean execute(String action, JSONArray args, CallbackContext callbackContext) throws JSONException {
        boolean ret = true;
        try {

            Log.d(LOG_TAG, "VLC EXECUTING ACTION: " + action);

            this.connectionCallbackContext = callbackContext;

            if (action.equalsIgnoreCase(INIT)) {

                JSONObject audio = null;

                if (playerService != null) {
                    audio = playerService.checkForExistingAudio();
                }

                PluginResult pluginResult;

                if (audio != null) {
                    JSONObject json = new JSONObject();
                    json.put("type", "current");
                    json.put("audio", audio);
                    pluginResult = new PluginResult(PluginResult.Status.OK, json);
                } else {
                    pluginResult = new PluginResult(PluginResult.Status.OK);
                }

                pluginResult.setKeepCallback(true);
                callbackContext.sendPluginResult(pluginResult);
            } else if (action.equals(PLAY_STREAM)) {

                JSONObject stationUrls = args.getJSONObject(0);
                JSONObject info = args.getJSONObject(1);
                JSONObject audioJson = null;
                if (args.length() > 2) {
                    audioJson = args.getJSONObject(2);
                }

                ret = playStream(stationUrls, info, audioJson);

                PluginResult pluginResult = new PluginResult(PluginResult.Status.OK);
                pluginResult.setKeepCallback(true);
                callbackContext.sendPluginResult(pluginResult);

            } else if (action.equals(PLAY_REMOTE_FILE)) {

                String file = args.getString(0);
                JSONObject info = args.getJSONObject(1);
                JSONObject audioJson = null;
                int position = 0;
                if (args.length() > 2) {
                    position = args.getInt(2);
                }
                if (args.length() > 3) {
                    audioJson = args.getJSONObject(3);
                }

                ret = playRemoteFile(file, info, position, audioJson);

                PluginResult pluginResult = new PluginResult(PluginResult.Status.OK);
                pluginResult.setKeepCallback(true);
                callbackContext.sendPluginResult(pluginResult);
            } else if (action.equals(PLAY_FILE)) {

                Log.d("PLAYER", action + " & Args: " + args.toString());

                String file = new File(args.getString(0)).getName();
                JSONObject info = args.getJSONObject(1);
                JSONObject audioJson = null;
                int position = 0;
                if (args.length() > 2) {
                    position = args.getInt(2);
                }
                if (args.length() > 3) {
                    audioJson = args.getJSONObject(3);
                }
                String directory = getDirectory(cordova.getActivity().getApplicationContext());
                file = stripArgumentsFromFilename(file);
                File f = new File(directory + "/" + file);

                if (f.exists()) {
                    ret = playAudioLocal(directory + "/" + file, info, position, audioJson);
                } else {
                    ret = playRemoteFile(args.getString(0), info, position, audioJson);
                }

                PluginResult pluginResult = new PluginResult(PluginResult.Status.OK);
                pluginResult.setKeepCallback(true);
                callbackContext.sendPluginResult(pluginResult);
            } else if (action.equals(PAUSE)) {

                playerService.pausePlaying();

                PluginResult pluginResult = new PluginResult(PluginResult.Status.OK);
                pluginResult.setKeepCallback(true);
                callbackContext.sendPluginResult(pluginResult);

            } else if (action.equals(SEEK)) {
                int interval = args.getInt(0);
                playerService.seekAudio(interval);

                PluginResult pluginResult = new PluginResult(PluginResult.Status.OK);
                pluginResult.setKeepCallback(true);
                callbackContext.sendPluginResult(pluginResult);

            } else if (action.equals(SEEK_TO)) {
                int pos = args.getInt(0);
                playerService.seekToAudio(pos);

                PluginResult pluginResult = new PluginResult(PluginResult.Status.OK);
                pluginResult.setKeepCallback(true);
                callbackContext.sendPluginResult(pluginResult);

            } else if (action.equals(STOP)) {
                //playerService.stopPlaying();
                playerService.pausePlaying();

                PluginResult pluginResult = new PluginResult(PluginResult.Status.OK);
                pluginResult.setKeepCallback(true);
                callbackContext.sendPluginResult(pluginResult);

            } else if (action.equals(HARD_STOP)) {
                playerService.stopPlaying();

                PluginResult pluginResult = new PluginResult(PluginResult.Status.OK);
                pluginResult.setKeepCallback(true);
                callbackContext.sendPluginResult(pluginResult);

            } else if (action.equals(SET_AUDIO_INFO)) {

//                JSONObject info = args.getJSONObject(0);
//                _setAudioInfo(info);
//                mAudioPlayer.setAudioInfo(info);

                PluginResult pluginResult = new PluginResult(PluginResult.Status.OK);
                pluginResult.setKeepCallback(true);
                callbackContext.sendPluginResult(pluginResult);

            } else if (action.equals(GET_AUDIO_STATE)) {

                playerService.fireAudioStateUpdated();

                PluginResult pluginResult = new PluginResult(PluginResult.Status.OK);
                pluginResult.setKeepCallback(true);
                callbackContext.sendPluginResult(pluginResult);

            } else {
                callbackContext.error(LOG_TAG + " error: invalid action (" + action + ")");
                ret = false;
            }
        } catch (JSONException e) {
            e.printStackTrace();
            callbackContext.error(LOG_TAG + " error: invalid json");
            ret = false;
        } catch (Exception e) {
            e.printStackTrace();
            callbackContext.error(LOG_TAG + " error: " + e.getMessage());
            ret = false;
        }
        return ret;
    }

    public static String stripArgumentsFromFilename(String filename) {
        int q = filename.lastIndexOf("?");
        if (q >= 0) {
            filename = filename.substring(0, q);
        }
        return filename;
    }

    public static String getDirectory(Context context) {
        // one-stop for directory, so it only needs to be changed here once
        // check if we can write to the SDCard

        boolean externalStorageAvailable;
        boolean externalStorageWriteable;
        String state = Environment.getExternalStorageState();

        if (Environment.MEDIA_MOUNTED.equals(state)) {
            // We can read and write the media
            externalStorageAvailable = externalStorageWriteable = true;
            //Log.d(LOG_TAG, "External Storage Available (Readable and Writeable)");
        } else if (Environment.MEDIA_MOUNTED_READ_ONLY.equals(state)) {
            // We can only read the media
            externalStorageAvailable = true;
            externalStorageWriteable = false;
            Log.d(LOG_TAG, "External Storage Read Only");
        } else {
            // Something else is wrong. It may be one of many other states, but all we need
            //  to know is we can neither read nor write
            externalStorageAvailable = externalStorageWriteable = false;
            Log.d(LOG_TAG, "External Storage Not Available");
        }

        // if we can write to the SDCARD
        if (externalStorageAvailable && externalStorageWriteable) {
            return context.getExternalFilesDir(Environment.DIRECTORY_MUSIC).getAbsolutePath() + "/";
        } else {
            return null;
        }
    }

    private boolean playAudioLocal(String file, JSONObject info, int position, JSONObject audioJson) throws JSONException, RemoteException, IOException {
        File f = new File(file);
        if (f.exists()) {
            // Set to Readable and MODE_WORLD_READABLE
            f.setReadable(true, false);
            Log.d(LOG_TAG, "is file readable? " + f.canRead());
        }

        String title = null;
        String artist = null;
        String imageUrl = null;

        if (info.has("title")) {
            title = info.getString("title");
        }
        if (info.has("artist")) {
            artist = info.getString("artist");
        }
        if (info.has("imageThumbnail")) {
            JSONObject thumbnailImage = info.getJSONObject("imageThumbnail");
            if (thumbnailImage.has("url")) {
                imageUrl = thumbnailImage.getString("url");
            }
        }

        file = "file://" + file;
        playAudio(file, title, artist, imageUrl, position, audioJson, false);

        return true;
    }

    private boolean playRemoteFile(String file, JSONObject info, int position, JSONObject audioJson) throws JSONException, RemoteException, IOException {
        String title = null;
        String artist = null;
        String imageUrl = null;
        boolean ret = false;

        if (this.isConnected()) {

            if (info.has("title")) {
                title = info.getString("title");
            }
            if (info.has("artist")) {
                artist = info.getString("artist");
            }
            if (info.has("imageThumbnail")) {
                JSONObject thumbnailImage = info.getJSONObject("imageThumbnail");
                if (thumbnailImage.has("url")) {
                    imageUrl = thumbnailImage.getString("url");
                }
            }

            playAudio(file, title, artist, imageUrl, position, audioJson, false);
            ret = true;
        } else {
            Log.d(LOG_TAG, "play remote file failed: no connection");
        }

        return ret;
    }

    private boolean playStream(JSONObject stationUrls, JSONObject info, JSONObject audioJson) throws JSONException, IOException, RemoteException {
        String url = null;
        try {
            url = stationUrls.getString("android");
        } catch (JSONException e) {
            e.printStackTrace();
        }

        String title = "";
        String artist = "";
        String imageUrl = null;
        boolean ret = false;

        if (this.isConnected()) {

            if (info != null && info.has("name")) {
                title = info.getString("name");
            }
            if (info != null && info.has("description")) {
                artist = info.getString("description");
            }
            if (info != null && info.has("imageThumbnail")) {
                JSONObject thumbnailImage = info.getJSONObject("imageThumbnail");
                if (thumbnailImage.has("url")) {
                    imageUrl = thumbnailImage.getString("url");
                }
            }

            playAudio(url, title, artist, imageUrl, -1, audioJson, true);
            ret = true;
        } else {
            Log.d(LOG_TAG, "play stream failed: no connection");
        }

        return ret;
    }

    public void playAudio(String file, String title, String artist, String url, int position, JSONObject audioJson, boolean isStream) throws RemoteException, IOException, JSONException {
        Log.d(LOG_TAG, "Playing audio -- " + file);

        playerService.startPlaying(file, title, artist, url, position, audioJson, isStream);
        //this.setAudioInfo(info);

    }

    protected boolean isConnected() {
        ConnectivityManager connectivity = (ConnectivityManager) webView.getContext().getSystemService(Context.CONNECTIVITY_SERVICE);

        if (connectivity.getActiveNetworkInfo() == null) {
            return false;
        } else if (connectivity.getActiveNetworkInfo().isConnected()) {
            return true;
        } else {
            return false;
        }
    }

    @Override
    public void onAudioStateUpdated(MediaPlayer.Event event) {
        if (this.connectionCallbackContext != null) {
            JSONObject o = new JSONObject();
            PluginResult result = null;
            try {
                o.put("type", "state");
                o.put("state", mapStates(event.type).ordinal());

                Field[] fields = MediaPlayer.Event.class.getDeclaredFields();
                for (Field f : fields) {
                    try {
                        if (f.getInt(event) == event.type) {
                            o.put("description", f.getName());
                            break;
                        }
                    } catch (IllegalAccessException e) {
                        Log.e(LOG_TAG, e.getMessage());
                    }
                }

                result = new PluginResult(PluginResult.Status.OK, o);
            } catch (JSONException e) {
                result = new PluginResult(PluginResult.Status.ERROR, e.getMessage());
            } finally {
                result.setKeepCallback(true);
                this.connectionCallbackContext.sendPluginResult(result);
            }
        }

        if (event.type == MediaPlayer.Event.Stopped) {
            onAudioProgressUpdated(0, 0);
        } else if (event.type == MediaPlayer.Event.TimeChanged) {
            int duration;
            try {
                duration = playerService.getDuration();
            } catch (NullPointerException e) {
                return;
            }
            onAudioProgressUpdated((int) event.getTimeChanged(), duration);
        }
    }

    /*
    // audio states
        MEDIA_NONE      : 0
        MEDIA_STARTING  : 1
        MEDIA_RUNNING   : 2
        MEDIA_PAUSED    : 3
        MEDIA_STOPPED   : 4
        MEDIA_LOADING   : 5
        MEDIA_COMPLETED : 6

        public static final int Opening = 258;
        public static final int Playing = 260;
        public static final int Paused = 261;
        public static final int Stopped = 262;
        public static final int EndReached = 265;
        public static final int EncounteredError = 266;
        public static final int TimeChanged = 267;
        public static final int PositionChanged = 268;
        public static final int Vout = 274;
        public static final int ESAdded = 276;
        public static final int ESDeleted = 277;
     */
    private CordovaMediaState mapStates(int type) {
        CordovaMediaState state;

        switch (type) {
            case MediaPlayer.Event.Opening:
                state = CordovaMediaState.MEDIA_LOADING;
                break;
            case MediaPlayer.Event.Playing:
                state = CordovaMediaState.MEDIA_RUNNING;
                break;
            case MediaPlayer.Event.Paused:
                state = CordovaMediaState.MEDIA_PAUSED;
                break;
            case MediaPlayer.Event.Stopped:
                state = CordovaMediaState.MEDIA_STOPPED;
                break;
            case MediaPlayer.Event.EndReached:
                state = CordovaMediaState.MEDIA_COMPLETED;
                break;
            case MediaPlayer.Event.TimeChanged:
                state = CordovaMediaState.MEDIA_RUNNING;
                break;
            case MediaPlayer.Event.PositionChanged:
                state = CordovaMediaState.MEDIA_RUNNING;
                break;
            default:
                state = CordovaMediaState.MEDIA_NONE;
                break;
        }

        return state;
    }

    @Override
    public void onAudioProgressUpdated(int progress, int duration) {
        Log.d(LOG_TAG, "Progress : " + progress + ", Duration : " + duration);
        if (this.connectionCallbackContext != null) {
            JSONObject o = new JSONObject();
            PluginResult result = null;
            try {
                o.put("type", "progress");
                o.put("progress", progress);
                o.put("duration", duration);
                o.put("available", -1);
                result = new PluginResult(PluginResult.Status.OK, o);
            } catch (JSONException e) {
                result = new PluginResult(PluginResult.Status.ERROR, e.getMessage());
            } finally {
                result.setKeepCallback(true);
                this.connectionCallbackContext.sendPluginResult(result);
            }
        }
    }

    @Override
    public void onAudioStreamingError(int reason) {
        if (this.connectionCallbackContext != null) {
            JSONObject o = new JSONObject();
            PluginResult result = null;
            try {
                o.put("type", "error");
                o.put("reason", reason);
                result = new PluginResult(PluginResult.Status.OK, o);
            } catch (JSONException e) {
                result = new PluginResult(PluginResult.Status.ERROR, e.getMessage());
            } finally {
                result.setKeepCallback(true);
                this.connectionCallbackContext.sendPluginResult(result);
            }
        }
    }

    @Override
    public void onAudioInterruptDetected(INTERRUPT_TYPE type, boolean trackInterrupt) {
        Log.d(LOG_TAG, "Audio Interrupt Detected - Stop audio if necessary.");
        playerService.interruptAudio(type, trackInterrupt);
    }

    @Override
    public void onAudioInterruptCompleted(INTERRUPT_TYPE type, boolean restart) {
        Log.d(LOG_TAG, "Audio Interrupt Completed - Restart audio if necessary.");

        try {
            playerService.clearAudioInterrupt(type, restart);
        } catch (IOException e) {  // TODO - how to handle?
            Log.d(LOG_TAG, "onAudioInterruptCompleted error: " + e.getMessage());
        }
    }

}
