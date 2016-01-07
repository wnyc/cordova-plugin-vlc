//
//  VLCPlugin.m
//
#import <AVFoundation/AVFoundation.h>
#import <MediaPlayer/MediaPlayer.h>
#include <objc/runtime.h>
#import "CDVSound.h"
#import "CDVReachability.h"
#import "VLCPlugin.h"
#import "DDLog.h"
#import <MWFeedParser/NSString+HTML.h>

extern int ddLogLevel;

static NSString *const kVLCPluginNoCloudDirectory = @"NoCloud";
static NSString *const kVLCPluginOldFileDirectory = @"Audio";
static NSString *const kVLCPluginFileDirectoryRelativeToLibrary = @"NoCloud/Audio";

static NSString * const kVLCPluginJSONOfflineSoundKey = @"offline_sound";
static NSString * const kVLCPluginJSONTypeKey = @"type";
static NSString * const kVLCPluginJSONStreamsKey = @"streams";
static NSString * const kVLCPluginJSONInfoKey = @"info";
static NSString * const kVLCPluginJSONAudioKey = @"audio";
static NSString * const kVLCPluginJSONIOSUrlKey = @"ios";
static NSString * const kVLCPluginJSONExtraKey = @"extra";
static NSString * const kVLCPluginJSONProgressKey = @"progress";
static NSString * const kVLCPluginJSONDurationKey = @"duration";
static NSString * const kVLCPluginJSONAvailableKey = @"available";
static NSString * const kVLCPluginJSONStateKey = @"state";
static NSString * const kVLCPluginJSONDescriptionKey = @"description";


static NSString * const kVLCPluginJSONAlarmNotificationValue = @"wakeup";
static NSString * const kVLCPluginJSONCurrentValue = @"current";
static NSString * const kVLCPluginJSONNextValue = @"next";
static NSString * const kVLCPluginJSONPreviousValue = @"previous";
static NSString * const kVLCPluginJSONStateValue = @"state";
static NSString * const kVLCPluginJSONProgressValue = @"progress";

static NSString * const kVLCPluginAudioMetadataKeyTitle = @"title";
static NSString * const kVLCPluginAudioMetadataKeyArtist = @"artist";
static NSString * const kVLCPluginAudioMetadataKeyImageObject = @"image";
static NSString * const kVLCPluginAudioMetadataKeyImageObjectUrl = @"url";
static NSString * const kVLCPluginAudioMetadataKeyLockscreenImageUrl = @"lockscreenImageUrl";

static NSString * const kVLCPluginVLCNetworkCachingKey = @"network-caching";
static NSString * const kVLCPluginVLCStartTimeKey = @"start-time";

static NSString * const kVLCPluginDiscoverAudioSelectedTypeKey = @"discoverAudioSelected";

static NSString * const kVLCPluginSaveAudioTypeKey = @"saveAudio";
static NSString * const kVLCPluginSaveAudioTypeKeyAudio = @"audio";
static NSString * const kVLCPluginIsAudioSaveAudioTypeKey = @"isAudioSaved";
static NSString * const kVLCPluginNextSavedAudioTypeKey = @"nextSavedAudio";
static NSString * const kVLCPluginNextSavedAudioTypeKeyOnCompletion = @"onCompletion";
static NSString * const kVLCPluginPreviousSavedAudioTypeKey = @"previousSavedAudio";

static NSString * const kVLCPluginDisplayShowTypeKey = @"displayShow";
static NSString * const kVLCPluginDisplayShowSlugKey = @"slug";

static NSString * const kVLCPluginSavedQueueTitle = @"queueTitle";
static NSString * const kVLCPluginSavedQueueTitleMyPlaylist = @"My Playlist";

static int const kVLCPluginWifiPrebuffer = 5000;
static int const kVLCPluginWanPrebuffer = 10000;
static int const kVLCPluginBufferTimeout = 60;
static int const kVLCPluginHeartbeatTimeout = 60;
static int const kVLCPluginRewindThreshold = 5000;

NSString * const VLCPluginRemoteControlEventNotification = @"VLCPluginRemoteControlEventNotification";

enum NYPRExtraMediaStates {
    //MEDIA_LOADING = MEDIA_STOPPED + 1, // deprecated
    MEDIA_COMPLETED = MEDIA_STOPPED + 2,
    //MEDIA_PAUSING = MEDIA_STOPPED + 3, // deprecated
    //MEDIA_STOPPING = MEDIA_STOPPED + 4  // deprecated
};
typedef NSUInteger NYPRExtraMediaStates;

@interface VLCPlugin ()

@property VLCMediaPlayer *mediaPlayer;
@property NYPRAudioPlayerViewController *audioPlayerViewController;
@property id <NYPRDiscoverAudioPlayerDelegate>discoverAudioPlaybackDelegate;
@property NYPRAudio *audio;
@property NYPRAudio *audioToBeDisplayed;
@property NYPRAudio *audioToBeSaved;
@property NSString *callbackId;
@property NSDictionary *currentAudio;
@property NSTimer *flushBufferTimer;
@property NSDictionary *lockScreenCache;
@property NSString *lockcreenImageUrl;
@property MPMediaItemArtwork *lockscreenMediaItemArtwork;
@property NSURLSessionDataTask *lockscreenImageDownloadTask;
@property NSTimer *heartbeatTimer;
@property NSTimeInterval lastHeartbeat;

@property (nonatomic) BOOL isDiscoverAudioSelected;
@property (nonatomic) BOOL isPlayingSavedAudioQueue;

@end

@implementation VLCPlugin

#pragma mark Initialization

- (void)pluginInitialize {

    [self vlc_checkForAndMoveFilesFromOldDirectory];

    // turn on remote control
   if ([[UIApplication sharedApplication] respondsToSelector:@selector(beginReceivingRemoteControlEvents)]){
      [[UIApplication sharedApplication] beginReceivingRemoteControlEvents];
    }
    [self.viewController becomeFirstResponder];
   
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(vlc_onRemoteControlEvent:) name:VLCPluginRemoteControlEventNotification object:nil];
    
    // watch for local notification
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(vlc_onLocalNotification:) name:CDVLocalNotification object:nil]; // if app is in foreground
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(vlc_onUIApplicationDidFinishLaunchingNotification:) name:UIApplicationDidFinishLaunchingNotification object:nil]; // if app is not in foreground or not running

    // watch for audio interruptions such as (un)plugged headphones, phone calls
    [AVAudioSession sharedInstance];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(vlc_audioRouteChangeListenerCallback:) name:AVAudioSessionRouteChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(vlc_audioInterruption:) name:AVAudioSessionInterruptionNotification object:[AVAudioSession sharedInstance]];
    
    [UIDevice currentDevice].batteryMonitoringEnabled=YES; // required to determine if device is charging
    
    [self vlc_create];
    
    DDLogInfo(@"VLC Plugin initialized");
    DDLogInfo(@"VLC Library Version %@", [[VLCLibrary sharedLibrary] version]);
    [self configureForDiscoverSDK];
}

- (void)configureForDiscoverSDK {
    [NYPRDiscoverSDK setUseAudioPlayer:NO];
    [NYPRDiscoverSDK setAudioPlayer:self];
    self.audioPlayerViewController = [NYPRDiscoverSDK getDiscoverPlayerViewController];
    self.audioPlayerViewController.delegate = self;
    self.discoverAudioPlaybackDelegate = [NYPRDiscoverSDK getDiscoverAudioPlaybackDelegate];
}

- (void)init:(CDVInvokedUrlCommand*)command {
    
    DDLogInfo (@"VLC Plugin configuring");
    
    CDVPluginResult* pluginResult = nil;
    
    if ( _currentAudio!=nil) {
        
        DDLogInfo(@"VLC Plugin sending current audio to js");
        
        NSDictionary * o = @{ kVLCPluginJSONTypeKey : kVLCPluginJSONCurrentValue,
                              kVLCPluginJSONAudioKey : _currentAudio};
        
        pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:o];
        
        _currentAudio = nil;
        
    } else {
        pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
    }
    [self vlc_sendPluginResult:pluginResult callbackId:command.callbackId];
}

- (void) vlc_create {
    self.mediaPlayer = [[VLCMediaPlayer alloc] init];
    self.mediaPlayer.delegate = self;
}

#pragma mark Cleanup

-(void) vlc_teardown {
    if (self.mediaPlayer) {

        if (self.mediaPlayer.media) {
            [self.mediaPlayer stop];
        }

        if (self.mediaPlayer) {
            self.mediaPlayer = nil;
        }
    }
}

- (void)dispose {
    DDLogInfo(@"VLC Plugin disposing");
    
    [self vlc_teardown];
   
    [[NSNotificationCenter defaultCenter] removeObserver:self name:CDVLocalNotification object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationDidFinishLaunchingNotification object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:VLCPluginRemoteControlEventNotification object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:AVAudioSessionRouteChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:AVAudioSessionInterruptionNotification object:[AVAudioSession sharedInstance]];
    
    if ([[UIApplication sharedApplication] respondsToSelector:@selector(endReceivingRemoteControlEvents)]){
      [[UIApplication sharedApplication] endReceivingRemoteControlEvents];
    }
 
    [super dispose];
}

#pragma mark Plugin handler

-(void)vlc_sendPluginResult:(CDVPluginResult*)result callbackId:(NSString*)callbackId{
    if (self.callbackId==nil){
        self.callbackId=callbackId;
    }
    
    if (self.callbackId!=nil){
        [result setKeepCallbackAsBool:YES]; // keep for later callbacks
        [self.commandDelegate sendPluginResult:result callbackId:self.callbackId];
    }
}

#pragma Audio playback commands

- (void)playstream:(CDVInvokedUrlCommand *)command {
    self.isDiscoverAudioSelected = NO;
    self.isPlayingSavedAudioQueue = NO;
    
    NYPRStream *stream = [NYPRStream createStream:[[NYPRPersistentStack sharedInstance] managedObjectContext]];
    [stream loadFromDictionary:[command.arguments lastObject]];
    
    self.audio = stream;
    self.audioPlayerViewController.audio = self.audio;

    CDVPluginResult* pluginResult = nil;
    NSString* url = [stream.url absoluteString];
    
    if ( url && url != (id)[NSNull null] ) {
        if([[CDVReachability reachabilityForInternetConnection] currentReachabilityStatus]!=NotReachable) {
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^() {
                [self vlc_playstream:url info:[self lockScreenMetadataForAudio:self.audio]];
            });
            pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
        } else {
            DDLogInfo (@"VLC Plugin cannot play stream because the internet is not reachable");
            pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"no connection"];
        }
    } else {
        DDLogInfo (@"VLC Plugin encountered invalid stream (%@)", url);
        pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"invalid stream url"];
    }
    
    [self vlc_sendPluginResult:pluginResult callbackId:command.callbackId];
}

- (void)vlc_playstream:(NSString *)url info:(NSDictionary *)info {
    DDLogInfo (@"VLC Plugin starting stream (%@)", url);
    
    VLCMediaPlayerState vlcState = self.mediaPlayer.state;
    VLCMediaState vlcMediaState = self.mediaPlayer.media.state;
    
    DDLogInfo(@"VLC Plugin audio state is %@ / %@", VLCMediaPlayerStateToString(vlcState), [self vlc_convertVLCMediaStateToString:vlcMediaState]);
    
    if (!self.mediaPlayer.media || ![self.mediaPlayer.media.url isEqual:[NSURL URLWithString:url] ] || vlcState==VLCMediaPlayerStateStopped || vlcState==VLCMediaPlayerStateError) { // no url or new url
        if(self.mediaPlayer.state == VLCMediaPlayerStatePaused) {
            // hack to fix WNYCAPP-1031 -- audio of new track is not playing if new track is played while current track is paused
            // better solution is to 'stop' current track/stream and wait for stopped event before playing, so current and new tracks don't step on each other in weird ways
            [self.mediaPlayer stop];
        }
        
        int prebuffer=kVLCPluginWanPrebuffer;
        NetworkStatus connectionType = [[CDVReachability reachabilityForInternetConnection] currentReachabilityStatus];
        
        if ( connectionType == ReachableViaWiFi) {
            prebuffer = kVLCPluginWifiPrebuffer;
        }

        self.mediaPlayer.media = [VLCMedia mediaWithURL:[NSURL URLWithString:url]];
        NSMutableDictionary *dictionary = [[NSMutableDictionary alloc] init];
        [dictionary setObject:@(prebuffer) forKey:kVLCPluginVLCNetworkCachingKey];
        [self.mediaPlayer.media addOptions:dictionary];
        
    }
    [self.mediaPlayer play];
    [self vlc_setlockscreenmetadata:info refreshLockScreen:false];
}

- (void)playfile:(CDVInvokedUrlCommand *)command {    
    NSDictionary *metadata = [command.arguments lastObject];
    NYPROnDemand *audio = [NYPROnDemand createOnDemandFromCordovaDictionary:metadata];

    self.isDiscoverAudioSelected = NO;
    self.isPlayingSavedAudioQueue = [[metadata objectForKey:kVLCPluginSavedQueueTitle] isEqualToString:kVLCPluginSavedQueueTitleMyPlaylist] ? YES : NO;
    
    if ( command.arguments.count > 2 && [command.arguments objectAtIndex:2] != (id)[NSNull null] ) {
        audio.elapsedTime = [command.arguments objectAtIndex:2];
    }
    
    [self playAudio:audio];
}

- (void)playAudio:(NYPRAudio *)audio {
    
    if ([[self.audio.playableUrl absoluteString] isEqualToString:[audio.playableUrl absoluteString]] && self.audio.state != NYPRAudioStatePaused && self.audio.state != NYPRAudioStateStopped) {
        return;
    }
    
    CDVPluginResult *pluginResult = nil;
    
    self.audio = audio;
    self.audioPlayerViewController.audio = self.audio;
    
    NSString *fullFilename = [audio.playableUrl absoluteString];
    NSInteger position = [audio.elapsedTime integerValue];
    
    if ( fullFilename && fullFilename != (id)[NSNull null] ) {
        
        NSString *fullPathAndFile;
        
        if (!self.isDiscoverAudioSelected) {
            // get the filename at the end of the file
            NSString *file = [[[NSURL URLWithString:fullFilename]  lastPathComponent] lowercaseString];
            NSString *path = [self vlc_getAudioDirectory];
            fullPathAndFile=[NSString stringWithFormat:@"%@%@",path, file];
        }
        else if ([[audio.playableUrl scheme] isEqualToString:@"file"]) {
            fullPathAndFile = [fullFilename stringByReplacingOccurrencesOfString:[NSString stringWithFormat:@"%@://",[audio.playableUrl scheme]] withString:@""];
        }
        else {
            fullPathAndFile = fullFilename;
        }
            
        if([[NSFileManager defaultManager] fileExistsAtPath:fullPathAndFile]){
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^() {
                DDLogInfo (@"VLC Plugin playing local file (%@)", fullPathAndFile);
                if (!self.mediaPlayer.media || ![self.mediaPlayer.media.url isEqual:[NSURL fileURLWithPath:fullPathAndFile] ]) { // no url or new url
                    if(self.mediaPlayer.state == VLCMediaPlayerStatePaused) {
                        // hack to fix WNYCAPP-1031 -- audio of new track is not playing if new track is played while current track is paused
                        // better solution is to 'stop' current track/stream and wait for stopped event before playing, so current and new tracks don't step on each other in weird ways
                        [self.mediaPlayer stop];
                    }
                    self.mediaPlayer.media = [VLCMedia mediaWithURL:[NSURL fileURLWithPath:fullPathAndFile]];
                }
                [self.mediaPlayer.media addOptions:@{kVLCPluginVLCStartTimeKey: @(position)}];
                [self.mediaPlayer play];
                [self vlc_setlockscreenmetadata:[self lockScreenMetadataForAudio:self.audio] refreshLockScreen:false];
            });
            pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
            
        } else {
            [self playRemoteAudio:audio];
        }
        
    }else {
        DDLogInfo (@"VLC Plugin encountered invalid file (%@)", fullFilename);
        pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"invalid local file url"];
    }
    
    if (pluginResult!=nil) {
        [self vlc_sendPluginResult:pluginResult callbackId:self.callbackId];
    }
}

- (void)playRemoteAudio:(NYPRAudio *)audio {
    CDVPluginResult* pluginResult = nil;
    
    NSString* url = [audio.playableUrl absoluteString];
    NSInteger position = [audio.elapsedTime integerValue];
    
    if ( url && url != (id)[NSNull null] ) {
        if([[CDVReachability reachabilityForInternetConnection] currentReachabilityStatus]!=NotReachable) {
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^() {
                DDLogInfo (@"VLC Plugin playing remote file (%@)", url);
                if (!self.mediaPlayer.media || ![self.mediaPlayer.media.url isEqual:[NSURL URLWithString:url] ] || self.mediaPlayer.state == VLCMediaPlayerStateStopped) { // no url or new url, or state is stopped (meaning a likely abnormal termination of playback)
                    if(self.mediaPlayer.state == VLCMediaPlayerStatePaused) {
                        // hack to fix WNYCAPP-1031 -- audio of new track is not playing if new track is played while current track is paused
                        // better solution is to 'stop' current track/stream and wait for stopped event before playing, so current and new tracks don't step on each other in weird ways
                        [self.mediaPlayer stop];
                    }
                    self.mediaPlayer.media = [VLCMedia mediaWithURL:[NSURL URLWithString:url]];
                    [self.mediaPlayer.media addOptions:@{kVLCPluginVLCStartTimeKey: @(position)}];
                } else if(self.mediaPlayer.state != VLCMediaPlayerStatePaused) {
                    [self.mediaPlayer.media addOptions:@{kVLCPluginVLCStartTimeKey: @(position)}];
                } else if (position>0) {
                    [self.mediaPlayer.media addOptions:@{kVLCPluginVLCStartTimeKey: @(position-1)}];
                }
                [self.mediaPlayer play];
                [self vlc_setlockscreenmetadata:[self lockScreenMetadataForAudio:self.audio] refreshLockScreen:false];
            });
            pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
        } else {
            DDLogInfo (@"VLC Plugin cannot play remote file because internet is not reachable");
            pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"no connection"];
        }
    } else {
        DDLogInfo (@"VLC Plugin encountered invalid remote file (%@)", url);
        pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"invalid remote file url"];
    }
    
    [self vlc_sendPluginResult:pluginResult callbackId:self.callbackId];
}

- (void)pause:(CDVInvokedUrlCommand*)command {
    [self pauseWithCallbackId:command.callbackId];
}

- (void)stop:(CDVInvokedUrlCommand*)command {
    [self stopPlayback];
}

- (void)setaudioinfo:(CDVInvokedUrlCommand*)command{
    NSDictionary  * info = [command.arguments  objectAtIndex:0];
    [self vlc_setlockscreenmetadata:info refreshLockScreen:true];
    
    if ([self.audio isKindOfClass:[NYPRStream class]] && [info objectForKey:@"svg_logo"]) {
        NYPRStream *stream = [NYPRStream createStream:[[NYPRPersistentStack sharedInstance] managedObjectContext]];
        [stream loadFromDictionary:info];
        self.audio = stream;
        self.audio.state = self.mediaPlayer.state;
        self.audioPlayerViewController.audio = self.audio;
    }
}

- (void)vlc_setlockscreenmetadata:(NSDictionary*)metadata refreshLockScreen:(BOOL)refreshLockScreen {
    self.lockScreenCache = [NSDictionary dictionaryWithDictionary:metadata];
    if(refreshLockScreen){
        [self vlc_setNowPlayingInfo:self.lockScreenCache retrieveLockscreenArt:YES];
    }
}

#pragma mark Audio playback controls

- (void)pauseWithCallbackId:(NSString *)callbackId {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^() {
        DDLogInfo (@"VLC Plugin pausing playback");
        if (self.mediaPlayer.isPlaying) {
            [self.mediaPlayer pause];
        }
    });
    
    CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
    [self vlc_sendPluginResult:pluginResult callbackId:callbackId];
}

- (void)stopPlayback {
    DDLogInfo (@"VLC Plugin stopping playback.");
    if (self.mediaPlayer.isPlaying) {
        [self.mediaPlayer stop];
        [self vlc_onAudioStreamUpdate:MEDIA_STOPPED description:[self vlc_convertAudioStateToString:MEDIA_STOPPED]];
    }
}

- (void)seekTo:(NSInteger)position withCallbackId:(NSString *)callbackId {
    CDVPluginResult* pluginResult = nil;
    
    DDLogInfo (@"VLC Plugin seeking to position (%ld)", (long)position );
    
    if ([self.mediaPlayer isSeekable]) {
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^() {
            float seconds=(float)position;
            float length=(float)[[self.mediaPlayer.media length] intValue] / 1000;
            float percent=seconds / length;
            [self.mediaPlayer setPosition:percent];
        });
        pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
    }else {
        DDLogInfo (@"VLC Plugin current audio is not seekable" );
        pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"audio not seekable"];
    }
    
    [self vlc_sendPluginResult:pluginResult callbackId:callbackId];
}

- (void)seekInterval:(NSInteger)interval withCallbackId:(NSString *)callbackId {
    CDVPluginResult* pluginResult = nil;
    
    if ([self.mediaPlayer isSeekable]){
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^() {
            DDLogInfo (@"VLC Plugin seeking to interval (%ld)", (long)interval );
            if (interval>0){
                [self.mediaPlayer jumpForward:((int)interval)];
            }else{
                [self.mediaPlayer jumpBackward:(-1*(int)interval)];
            }
        });
        pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
    } else {
        DDLogInfo (@"VLC Plugin current audio is not seekable" );
        pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"audio not seekable"];
    }
    
    [self vlc_sendPluginResult:pluginResult callbackId:self.callbackId];
}

#pragma mark Audio playback event handlers

- (void)mediaPlayerTimeChanged:(NSNotification *)aNotification {
    [self updateAudioProgress];
    self.lastHeartbeat = [[NSDate date] timeIntervalSince1970];
    //DDLogInfo(@"mediaPlayerTimeChanged %d/%d/%d", [[self.mediaPlayer time]intValue], [[self.mediaPlayer remainingTime]intValue], [[self.mediaPlayer.media length] intValue]);
}

- (void)updateAudioProgress {
    self.audio.duration = [self vlc_getDuration];
    self.audio.elapsedTime = [self vlc_getElapsedTime];
    [self vlc_onAudioProgressUpdate:[[self.mediaPlayer time]intValue] duration:[[self.mediaPlayer.media length] intValue] available:-1];
}

- (void)mediaPlayerStateChanged:(NSNotification *)aNotification {
    VLCMediaPlayerState vlcState = self.mediaPlayer.state;
    VLCMediaState vlcMediaState = self.mediaPlayer.media.state;
    
    NSString * description=@"";
    int state = MEDIA_NONE;
    
    DDLogInfo(@"VLC Plugin audio player state has changed to %@ / %@", VLCMediaPlayerStateToString(vlcState), [self vlc_convertVLCMediaStateToString:vlcMediaState]);
    
    [self vlc_clearFlushBufferTimer];

    switch (vlcState) {
        case VLCMediaPlayerStateStopped:
            state = MEDIA_STOPPED;
            if (self.mediaPlayer) {
                DDLogInfo(@"VLC Plugin audio has stopped. times: %d/%d", [[self.mediaPlayer time]intValue], [[self.mediaPlayer remainingTime]intValue]);
                if (self.mediaPlayer.media ) {
                    DDLogInfo(@"VLC Plugin audio length: %d", [[self.mediaPlayer.media length] intValue]);
                    // regard track as completed if it ends within 1/2 second of length...
                    if ([[self.mediaPlayer.media length] intValue]>0 && [[self.mediaPlayer remainingTime]intValue]>=-500 ) {
                        DDLogInfo(@"VLC Plugin audio track has completed");
                        // send final progress update -- the delegate function (mediaPlayerTimeChanged) doesn't seem to fire
                        // for length:length -- the final call to it is for a time less than the track time, so simulate it here...
                        [self vlc_onAudioProgressUpdate:[[self.mediaPlayer.media length]intValue] duration:[[self.mediaPlayer.media length] intValue] available:-1];
                        // send complete event
                        [self respondToPlaybackCompleted];
                    }
                }
            }
            break;
        case VLCMediaPlayerStateOpening:
            state = MEDIA_STARTING;
            break;
        case VLCMediaPlayerStateBuffering:
            if ( vlcMediaState == VLCMediaStatePlaying ) {
                state = MEDIA_RUNNING;
            } else {
                state = MEDIA_STARTING;
            }
            break;
        case VLCMediaPlayerStateEnded:
            state = MEDIA_COMPLETED;
            break;
        case VLCMediaPlayerStateError:
            state = MEDIA_STOPPED;
            break;
        case VLCMediaPlayerStatePlaying:
            state = MEDIA_RUNNING;
            break;
        case VLCMediaPlayerStatePaused:
            state = MEDIA_PAUSED;
            [self vlc_setFlushBufferTimer];
            break;
        default:
            state = MEDIA_NONE;
            break;
    };
    
    self.audio.state = state;
    
    description = [self vlc_convertAudioStateToString:state];
    
    if (state == MEDIA_RUNNING) {
        [self vlc_setHeartbeatTimer];
    } else {
        [self vlc_clearHeartbeatTimer];
    }
    
    [self vlc_onAudioStreamUpdate:state description:description];
    
    if ([UIDevice currentDevice].batteryState == UIDeviceBatteryStateCharging || [UIDevice currentDevice].batteryState == UIDeviceBatteryStateFull ) {
        // device is charging - disable automatic screen-locking
        [UIApplication sharedApplication].idleTimerDisabled = YES;
    } else {
        // VLC disables the idle timer which controls automatic screen-locking whenever audio/video is playing. re-enable it here, since we are playing audio and disabling automatic
        // screen-locking is more appropriate for video.
        [UIApplication sharedApplication].idleTimerDisabled = NO;
    }
}

- (void)respondToPlaybackCompleted {
    if (self.isDiscoverAudioSelected) {
        self.audio.completed = YES;
    } else if (self.isPlayingSavedAudioQueue) {
        [self initiateNextSavedQueueAudioPlaybackOnCompletion:YES];
    } else {
        [self vlc_onAudioStreamUpdate:MEDIA_COMPLETED description:[self vlc_convertAudioStateToString:MEDIA_COMPLETED]];
        self.audio = nil;
        self.audioPlayerViewController.audio = nil;
    }
}

- (void)initiateNextSavedQueueAudioPlaybackOnCompletion:(BOOL)completion {
    NSDictionary *pluginResultMessage = @{  kVLCPluginJSONTypeKey : kVLCPluginNextSavedAudioTypeKey,
                                            kVLCPluginNextSavedAudioTypeKeyOnCompletion : @(completion) };
    
    CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:pluginResultMessage];
    [self vlc_sendPluginResult:pluginResult callbackId:self.callbackId];
}

- (void)initiatePreviousSavedQueueAudioPlayback {
    NSDictionary *pluginResultMessage = @{ kVLCPluginJSONTypeKey : kVLCPluginPreviousSavedAudioTypeKey };
    
    CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:pluginResultMessage];
    [self vlc_sendPluginResult:pluginResult callbackId:self.callbackId];
}

- (void) vlc_onAudioStreamUpdate:(int)state description:(NSString*)description {
    DDLogInfo(@"VLC Plugin posting state change: %@", description);
    
    NSDictionary * o = @{ kVLCPluginJSONTypeKey : kVLCPluginJSONStateValue, kVLCPluginJSONStateKey : [NSNumber numberWithInt:state], kVLCPluginJSONDescriptionKey : description };
    CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:o];
    [self vlc_sendPluginResult:pluginResult callbackId:self.callbackId];
    
    [self vlc_setNowPlayingInfo:self.lockScreenCache retrieveLockscreenArt:YES];
}

- (void) vlc_onAudioProgressUpdate:(long) progress duration:(long)duration available:(long)available {
    NSDictionary * o = @{ kVLCPluginJSONTypeKey : kVLCPluginJSONProgressValue,
                          kVLCPluginJSONProgressKey : [NSNumber numberWithInt:(int)progress] ,
                          kVLCPluginJSONDurationKey : [NSNumber numberWithInt:(int)duration],
                          kVLCPluginJSONAvailableKey : [NSNumber numberWithInt:(int)available]};
    
    CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:o];
    [self vlc_sendPluginResult:pluginResult callbackId:self.callbackId];
    
    [self vlc_setNowPlayingInfo:self.lockScreenCache retrieveLockscreenArt:YES];
}

- (void) vlc_onRemoteControlEvent:(NSNotification *) notification {
    if ([[notification name] isEqualToString:VLCPluginRemoteControlEventNotification]){
        NSDictionary *dict = [notification userInfo];
        NSNumber * buttonId = [dict objectForKey:(@"buttonId")];
        
        switch ([buttonId intValue]){
            case UIEventSubtypeRemoteControlTogglePlayPause:
                DDLogInfo(@"VLC Plugin remote control play/pause");
                if (self.mediaPlayer.isPlaying){
                    [self.mediaPlayer pause];
                }else{
                    [self.mediaPlayer play];
                }
                break;
                
            case UIEventSubtypeRemoteControlPlay:
                DDLogInfo(@"VLC Plugin remote control play");
                [self.mediaPlayer play];
                break;
                
            case UIEventSubtypeRemoteControlPause:
                DDLogInfo(@"VLC Plugin remote control pause");
                [self.mediaPlayer pause];
                break;
                
            case UIEventSubtypeRemoteControlStop:
                DDLogInfo(@"VLC Plugin remote control stop");
                [self.mediaPlayer pause];
                break;
                
            case UIEventSubtypeRemoteControlNextTrack:
                DDLogInfo(@"VLC Plugin remote control next track");
                [self nextButtonTapped];
                break;
                
            case UIEventSubtypeRemoteControlPreviousTrack:
                DDLogInfo(@"VLC Plugin remote control previous track");
                [self previousButtonTapped];
                break;
                
            case UIEventSubtypeRemoteControlBeginSeekingBackward:
                DDLogInfo(@"VLC Plugin remote control begin seeking backward");
                break;
                
            case UIEventSubtypeRemoteControlEndSeekingBackward:
                DDLogInfo(@"VLC Plugin remote control end seeking backward");
                break;
                
            case UIEventSubtypeRemoteControlBeginSeekingForward:
                DDLogInfo(@"VLC Plugin remote control begin seeking forward");
                break;
                
            case UIEventSubtypeRemoteControlEndSeekingForward:
                DDLogInfo(@"VLC Plugin Remote control end seeking forward");
                break;
                
            default:
                DDLogInfo(@"VLC Plugin remote control unknown command");
                break;
        }
    }
}

- (void)queueCompleted:(CDVInvokedUrlCommand*)command {
    [self vlc_onAudioStreamUpdate:MEDIA_COMPLETED description:[self vlc_convertAudioStateToString:MEDIA_COMPLETED]];
    self.audio = nil;
    self.audioPlayerViewController.audio = nil;
}

#pragma mark Misc

- (NSString*) vlc_convertVLCMediaStateToString:(VLCMediaState) state{
    switch (state){
        case VLCMediaStateNothingSpecial:
            return @"VLCMediaStateNothingSpecial";
        case VLCMediaStateBuffering:
            return @"VLCMediaStateBuffering";
        case VLCMediaStatePlaying:
            return @"VLCMediaStatePlaying";
        case VLCMediaStateError:
            return @"VLCMediaStateError";
        default:
           return @"VLCMediaStateUnknown";
    }
}

- (NSString*) vlc_convertAudioStateToString:(int) state{
    NSString * description;
    switch (state) {
        case MEDIA_STOPPED:
            description = @"MEDIA_STOPPED";
            break;
        case MEDIA_STARTING:
            description = @"MEDIA_STARTING";
            break;
        case MEDIA_RUNNING:
            description = @"MEDIA_RUNNING";
            break;
        case MEDIA_COMPLETED:
            description = @"MEDIA_COMPLETED";
            break;
        case MEDIA_PAUSED:
            description = @"MEDIA_PAUSED";
            break;
        default:
            description = @"MEDIA_NONE";
            break;
    };
    
    return description;

}

#pragma mark Flush buffer methods

- (void) vlc_setFlushBufferTimer {
    if (self.flushBufferTimer) {
        [self.flushBufferTimer invalidate];
    }
    self.flushBufferTimer = [NSTimer scheduledTimerWithTimeInterval: kVLCPluginBufferTimeout
                                              target: self
                                            selector: @selector(vlc_flushBuffer)
                                            userInfo: nil
                                             repeats: NO];
}

- (void) vlc_flushBuffer {
    DDLogInfo(@"VLC Plugin flushing buffer");
    [self.mediaPlayer stop];
}

- (void) vlc_clearFlushBufferTimer {
    [self.flushBufferTimer invalidate];
}

#pragma mark Heartbeat methods

- (void) vlc_setHeartbeatTimer {
    if (self.heartbeatTimer) {
        [self.heartbeatTimer invalidate];
    }
    self.heartbeatTimer = [NSTimer scheduledTimerWithTimeInterval: kVLCPluginHeartbeatTimeout
                                                             target: self
                                                           selector: @selector(vlc_checkHeartbeat)
                                                           userInfo: nil
                                                            repeats: NO];
}

- (void) vlc_checkHeartbeat {
    NSTimeInterval secondsSinceLastHeartbeat = [[NSDate date] timeIntervalSince1970] - self.lastHeartbeat;
    if (secondsSinceLastHeartbeat >= kVLCPluginHeartbeatTimeout) {
        DDLogInfo(@"VLC Plugin audio playback heartbeat expired");
        [self.mediaPlayer stop];
    }
    else {
        self.heartbeatTimer = [NSTimer scheduledTimerWithTimeInterval: kVLCPluginHeartbeatTimeout - secondsSinceLastHeartbeat
                                                                   target: self
                                                                 selector: @selector(vlc_checkHeartbeat)
                                                                 userInfo: nil
                                                                  repeats: NO];
    }
}

- (void) vlc_clearHeartbeatTimer {
    [self.heartbeatTimer invalidate];
}


#pragma mark Lock Screen Metadata

- (NSDictionary *)lockScreenMetadataForAudio:(NYPRAudio *)audio {
    NSString *title = [self titleForAudio:audio];
    NSString *subtitle = [self subtitleForAudio:audio];
    NSString *imageFileUrl = [audio.imageFileUrl absoluteString] ? [audio.imageFileUrl absoluteString] : @"";

    NSDictionary *metadata;
    
    if (imageFileUrl) {
        metadata = @{kVLCPluginAudioMetadataKeyTitle : title, kVLCPluginAudioMetadataKeyArtist : subtitle, kVLCPluginAudioMetadataKeyLockscreenImageUrl : imageFileUrl };
    }
    else {
        metadata = @{kVLCPluginAudioMetadataKeyTitle : title, kVLCPluginAudioMetadataKeyArtist : subtitle };
    }

    return metadata;
}

- (NSString *)titleForAudio:(NYPRAudio *)audio {
    NSString *title;
    if ([audio isKindOfClass:[NYPRStream class]]) {
        title = [(NYPRStream *)audio whatsOnDescription] ? [[(NYPRStream *)audio whatsOnDescription] stringByConvertingHTMLToPlainText] : @"";
    } else {
        title = audio.displayTitle ? audio.displayTitle : @"";
    }
    return title;
}

- (NSString *)subtitleForAudio:(NYPRAudio *)audio {
    NSString *subtitle;
    if ([audio isKindOfClass:[NYPRStream class]]) {
        subtitle = [(NYPRStream *)audio showTitle] ? [(NYPRStream *)audio showTitle] : @"";
    } else {
        subtitle = audio.displaySubtitle ?  audio.displaySubtitle : @"";
    }
    return subtitle;
}

- (void) vlc_setNowPlayingInfo:(NSDictionary*)info retrieveLockscreenArt:(BOOL)retrieveLockscreenArt {
    
    NSString *title=@"";
    NSString *artist=@"";
    NSString *artworkURL;
    
    NSNumber *elapsedPlaybackTime=[self vlc_getElapsedTime];
    NSNumber *playbackDuration=[self vlc_getDuration];
    
    MPMediaItemArtwork *mediaItemArtwork=nil;
    
    if (info) {
        if ([info objectForKey:kVLCPluginAudioMetadataKeyTitle]!=nil) {
            title = [info objectForKey:kVLCPluginAudioMetadataKeyTitle];
        }
        
        if ([info objectForKey:kVLCPluginAudioMetadataKeyArtist]!=nil) {
            artist = [info objectForKey:kVLCPluginAudioMetadataKeyArtist];
        }
        
        
        if ([info objectForKey:kVLCPluginAudioMetadataKeyLockscreenImageUrl]!=nil) {
            artworkURL = [info objectForKey:kVLCPluginAudioMetadataKeyLockscreenImageUrl];
        }
        else {
            NSDictionary * artwork = [info objectForKey:kVLCPluginAudioMetadataKeyImageObject];
            if (artwork && artwork != (id)[NSNull null] && [artwork objectForKey:kVLCPluginAudioMetadataKeyImageObjectUrl] != nil){
                DDLogInfo(@"VLC Plugin Lockscreen image found at json path image.url, which is deprecated. Please switch to lockscreenImageUrl.");
                artworkURL = [artwork objectForKey:kVLCPluginAudioMetadataKeyImageObjectUrl];
            }
        }
        
        mediaItemArtwork = [self vlc_getLockScreenImage:artworkURL retrieveLockscreenArt:retrieveLockscreenArt];
    }
    
    NSNumber *playbackRate = self.mediaPlayer.isPlaying ? [NSNumber numberWithFloat:1.0f] : [NSNumber numberWithFloat:0.0f];
    
    NSDictionary *nowPlaying;
    
    if (mediaItemArtwork) {
        nowPlaying = @{
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: artist,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsedPlaybackTime,
            MPMediaItemPropertyPlaybackDuration: playbackDuration,
            MPMediaItemPropertyArtwork: mediaItemArtwork,
            MPNowPlayingInfoPropertyPlaybackRate : playbackRate,
        };
    }
    else {
        nowPlaying = @{
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: artist,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsedPlaybackTime,
            MPMediaItemPropertyPlaybackDuration: playbackDuration,
            MPNowPlayingInfoPropertyPlaybackRate : playbackRate,
        };
    }
    
    MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo = nowPlaying;
}

- (NSNumber *)vlc_getElapsedTime {
    float _elapsedPlaybackTime = self.mediaPlayer ? ([[self.mediaPlayer time]intValue] / 1000): 0.0f;
    NSNumber *elapsedPlaybackTime = @(_elapsedPlaybackTime);
    return elapsedPlaybackTime;
}

- (NSNumber *)vlc_getDuration {
    float _playbackDuration = (self.mediaPlayer && self.mediaPlayer.media) ? ([[self.mediaPlayer.media length]intValue]/1000) : 0.0f;
    NSNumber *playbackDuration;
    if (_playbackDuration==0.0f){
        playbackDuration=[self vlc_getElapsedTime];
    }
    else {
        playbackDuration = @(_playbackDuration);
    }
    return playbackDuration;
}


- (MPMediaItemArtwork *)vlc_getLockScreenImage:(NSString *)artworkURL retrieveLockscreenArt:(BOOL)retrieveLockscreenArt {
    MPMediaItemArtwork *mediaItemArtwork;
    
    if (artworkURL) {
        if (self.lockcreenImageUrl && [artworkURL isEqualToString:self.lockcreenImageUrl]) {
            // use current artwork object if it exists...
            if (self.lockscreenMediaItemArtwork!=nil) {
                mediaItemArtwork = self.lockscreenMediaItemArtwork;
            }
            else {
                // otherwise, retrieve the artwork...
                if (retrieveLockscreenArt) {
                    [self vlc_retrieveLockscreenImage:artworkURL];
                }
            }
        }
        else {
            // artwork has changed, remove any current artwork, cancel current retrieval task
            if (!self.lockscreenImageDownloadTask) {
                [self.lockscreenImageDownloadTask cancel];
            }
            
            // and then retreive...
            if (retrieveLockscreenArt) {
                [self vlc_retrieveLockscreenImage:artworkURL];
            }
        }
    }
    else {
        // no artwork for this audio... cancel current download task
        if (!self.lockscreenImageDownloadTask) {
            [self.lockscreenImageDownloadTask cancel];
        }
    }
    
    return mediaItemArtwork;
}

- (void)vlc_retrieveLockscreenImage:(NSString *)artworkUrl {
    if ( [[CDVReachability reachabilityForInternetConnection] currentReachabilityStatus] != NotReachable) {  // is the network available?
        if (!self.lockscreenImageDownloadTask || self.lockscreenImageDownloadTask.state != NSURLSessionTaskStateRunning) { // is the artwork already downloading?
        
            DDLogInfo(@"VLC Plugin retrieving lock screen art from %@", artworkUrl);

            NSURL *url = [NSURL URLWithString:artworkUrl];
            NSURLRequest *request = [NSURLRequest requestWithURL:url];
            NSURLSession *session = [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration defaultSessionConfiguration]];
            self.lockscreenImageDownloadTask = [session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error){
                if (!error) {
                    DDLogInfo(@"VLC Plugin done retrieving lock screen art");
                
                    UIImage *image = [[UIImage alloc] initWithData:data];
                    MPMediaItemArtwork *mediaItemArtwork = [[MPMediaItemArtwork alloc] initWithImage:image];
     
                    self.lockscreenMediaItemArtwork = mediaItemArtwork;
                    self.lockcreenImageUrl = artworkUrl;
                
                    [self vlc_setNowPlayingInfo:self.lockScreenCache retrieveLockscreenArt:NO];
                }
                else {
                    DDLogInfo(@"VLC Plugin error occured while retrieving lock screen art:");
                    DDLogInfo(@"%@", error.localizedDescription );
                    DDLogInfo(@"%@", error.localizedFailureReason );
                    DDLogInfo(@"%@", error.localizedRecoveryOptions );
                }
            }];
            [self.lockscreenImageDownloadTask resume];
        }
        else {
            DDLogInfo(@"VLC Plugin skipping download -- already in progress for %@", artworkUrl);
        }
    }else{
        DDLogInfo(@"VLC Plugin offline - not retrieving lock screen art");
    }
}

#pragma mark Notification handlers

- (void)vlc_onLocalNotification:(NSNotification *)notification {
    DDLogInfo(@"VLC Plugin received local notification while app is running");
    
    UILocalNotification* localNotification = [notification object];
    
    [self vlc_playStreamFromLocalNotification:localNotification];
}


-(void)vlc_onUIApplicationDidFinishLaunchingNotification:(NSNotification*)notification {
    
    NSDictionary *userInfo = [notification userInfo] ;
    UILocalNotification *localNotification = [userInfo objectForKey:UIApplicationLaunchOptionsLocalNotificationKey];
    if (localNotification) {
        [self vlc_playStreamFromLocalNotification:localNotification];
    }
}

-(void)vlc_playStreamFromLocalNotification:(UILocalNotification*)localNotification {
    NSString * notificationType = [[localNotification userInfo] objectForKey:kVLCPluginJSONTypeKey];
    
    if ( notificationType!=nil && [notificationType isEqualToString:kVLCPluginJSONAlarmNotificationValue]) {
        DDLogInfo(@"VLC Plugin alarm detected");
        
        NSString * s = [[localNotification userInfo] objectForKey:kVLCPluginJSONExtraKey];
        NSError *error;
        NSData *data = [s dataUsingEncoding:NSUTF8StringEncoding];
        NSDictionary *extra = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
        
        if([[CDVReachability reachabilityForInternetConnection] currentReachabilityStatus]!=NotReachable) {
        
            if (extra!=nil){
                NSDictionary  * streams = [extra objectForKey:kVLCPluginJSONStreamsKey];
                NSDictionary  * info = [extra objectForKey:kVLCPluginJSONInfoKey];
                NSDictionary  * audio = [extra objectForKey:kVLCPluginJSONAudioKey];
                NSString* url = nil;
            
                if (streams) {
                    url=[streams objectForKey:kVLCPluginJSONIOSUrlKey];
                    if (url!=nil) {
                        [self vlc_playstream:url info:info];
                    
                        if (self.callbackId!=nil && audio!=nil) {
                            NSDictionary * o = @{ kVLCPluginJSONTypeKey : kVLCPluginJSONCurrentValue,
                                                kVLCPluginJSONAudioKey : audio};
                        
                            CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:o];
                            [self vlc_sendPluginResult:pluginResult callbackId:self.callbackId];
                        
                            self.currentAudio = nil;
                        } else {
                            self.currentAudio = audio; // send this when callback is available
                        }
                    }
                }
            }
            else {
                DDLogInfo(@"VLC Plugin alarm contains no configuration information");
            }
        } else {
            DDLogInfo(@"VLC Plugin cannot play alarm stream because internet is not reachable");
            if (extra!=nil) {
                NSString  * sound = [extra objectForKey:kVLCPluginJSONOfflineSoundKey];
                NSURL *resourceURLString = [[NSBundle mainBundle] resourceURL];
                NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@%@",resourceURLString, sound]];
                self.mediaPlayer.media = [VLCMedia mediaWithURL:url];
                [self.mediaPlayer play];
            }
        }
    }
}

#pragma mark Headphone handler
- (void)vlc_audioRouteChangeListenerCallback:(NSNotification*)notification {
    NSDictionary *interuptionDict = notification.userInfo;
    
    NSInteger routeChangeReason = [[interuptionDict valueForKey:AVAudioSessionRouteChangeReasonKey] integerValue];

    switch (routeChangeReason) {
            
        case AVAudioSessionRouteChangeReasonNewDeviceAvailable:
            DDLogInfo(@"VLC Plugin headphone/line plugged in");
            break;
            
        case AVAudioSessionRouteChangeReasonOldDeviceUnavailable:
            DDLogInfo(@"VLC Plugin stopping audio player because headphone/line disconnected");
            if([self.mediaPlayer isPlaying]) {
                [self.mediaPlayer pause];
            }
            break;
            
        case AVAudioSessionRouteChangeReasonCategoryChange:
            // called at start - also when other audio wants to play
            break;
    }
}

- (void)vlc_audioInterruption:(NSNotification*)notification {
    AVAudioSessionInterruptionType interruptionType = [[[notification userInfo] objectForKey:AVAudioSessionInterruptionTypeKey] unsignedIntegerValue];
    if (AVAudioSessionInterruptionTypeBegan == interruptionType) {
        DDLogInfo(@"VLC Plugin stopping audio player because headphone/line disconnected");
        [self.mediaPlayer pause];
    }else if (AVAudioSessionInterruptionTypeEnded == interruptionType){
        DDLogInfo(@"VLC Plugin resumed audio player after headphone/line disconnected");
        [self.mediaPlayer play];
    }
}


#pragma mark File management functions

- (void)vlc_checkForAndMoveFilesFromOldDirectory {
    NSFileManager *fileManager = [NSFileManager defaultManager];

    NSString *oldAudioDirectory = [self vlc_getOldAudioDirectory];
    BOOL oldAudioDirectoryExists = [fileManager fileExistsAtPath:oldAudioDirectory];

    if (!oldAudioDirectoryExists) {
        return;
    }

    NSString *newAudioDirectory = [self vlc_getAudioDirectory];
    BOOL newAudioDirectoryExists = [fileManager fileExistsAtPath:newAudioDirectory];
    NSError *__autoreleasing *error = nil;

    if (newAudioDirectoryExists) {
        [fileManager removeItemAtPath:oldAudioDirectory error:error];
        if (error) {
            DDLogInfo(@"VLC Plugin error removing old audio directory");
        }
        return;
    }

    [self vlc_checkForAndCreateLibraryNoCloudDirectory];

    error = nil;
    [fileManager moveItemAtPath:oldAudioDirectory toPath:newAudioDirectory error:error];
    if (error) {
        DDLogInfo(@"VLC Plugin error moving old audio directory to new audio directory");
    }
}

- (NSString *)vlc_getOldAudioDirectory {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documentsDirectory = [paths objectAtIndex:0];
    NSString *path = [NSString stringWithFormat:@"%@/%@/",documentsDirectory, kVLCPluginOldFileDirectory];
    return path;
}

- (NSString *)vlc_getAudioDirectory {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES);
    NSString *libraryDirectory = [paths objectAtIndex:0];
    NSString *path = [NSString stringWithFormat:@"%@/%@/",libraryDirectory, kVLCPluginFileDirectoryRelativeToLibrary];
    return path;
}

- (void)vlc_checkForAndCreateLibraryNoCloudDirectory {
    // safeguard - Library/NoCloud should be created by Cordova
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES);
    NSString *libraryDirectory = [paths objectAtIndex:0];
    NSString *path = [NSString stringWithFormat:@"%@/%@/",libraryDirectory, kVLCPluginNoCloudDirectory];

    BOOL noCloudDirectoryExists = [fileManager fileExistsAtPath:path];
    NSError *__autoreleasing *error = nil;

    if (!noCloudDirectoryExists) {
        [fileManager createDirectoryAtPath:path withIntermediateDirectories:FALSE attributes:nil error:error];
        NSAssert(!error, @"Could not create directory at %@", path);
    }
}

#pragma mark NYPRDiscoverAudioPlayer Protocol methods

- (void)playDiscoverFile:(NYPRAudio *)audio position:(NSInteger)position holdPlayback:(BOOL)holdPlayback reload:(BOOL)reload {
    self.isDiscoverAudioSelected = YES;
    self.isPlayingSavedAudioQueue = NO;
    
    NSDictionary *pluginResultMessage = @{ kVLCPluginJSONTypeKey : kVLCPluginDiscoverAudioSelectedTypeKey };
    
    CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:pluginResultMessage];
    [self vlc_sendPluginResult:pluginResult callbackId:self.callbackId];
    
    [self playAudio:audio];
}

- (void)pauseDiscover {
    [self pauseWithCallbackId:self.callbackId];
}

- (void)stopDiscover {
    [self stopPlayback];
}

- (void)audioPlayerSetAudioSaved:(NYPRAudio *)audio saved:(BOOL)saved {
    self.audioToBeSaved = audio;
    [self getSavedStatusForAudio:audio];
}

- (void)audioPlayerGetAudioSaved:(NYPRAudio *)audio {
    self.audioToBeDisplayed = audio;
    [self getSavedStatusForAudio:audio];
}

#pragma mark NYPRAudioPlayerViewControllerDelegate methods

- (void)nextButtonTapped {
    if (self.isDiscoverAudioSelected) {
        [self playNextDiscoverTrack];
    } else if (self.isPlayingSavedAudioQueue) {
        [self initiateNextSavedQueueAudioPlaybackOnCompletion:NO];
    }
}

- (void)previousButtonTapped {
    if ([[self.mediaPlayer time] intValue] > kVLCPluginRewindThreshold && [self.audio isKindOfClass:[NYPROnDemand class]]) {
        [self seekToPosition:0];
        return;
    }
    
    if (self.isDiscoverAudioSelected) {
        [self.discoverAudioPlaybackDelegate discoverPlayerPreviousTrack];
    } else if (self.isPlayingSavedAudioQueue) {
        [self initiatePreviousSavedQueueAudioPlayback];
    }
}

- (void)rewindButtonTapped:(NSInteger)interval {
    [self seekInterval:interval withCallbackId:self.callbackId];
}

- (void)playButtonTapped {
    if (self.mediaPlayer.state != VLCMediaPlayerStatePlaying) {
        [self playAudio:self.audio];
    }
}

- (void)pauseButtonTapped {
    if (self.mediaPlayer.state != VLCMediaPlayerStatePaused) {
        [self.mediaPlayer pause];
    }
}

- (void)seekToPosition:(NSInteger)position {
    [self seekTo:position withCallbackId:self.callbackId];
}

- (void)visualPlayerSetAudioSaved:(NYPRAudio *)audio saved:(BOOL)saved {
    self.audioToBeSaved = audio;
    [self getSavedStatusForAudio:audio];
}

- (void)visualPlayerGetAudioSaved:(NYPRAudio *)audio {
    self.audioToBeDisplayed = audio;
    [self getSavedStatusForAudio:audio];
}

#pragma mark Display Show methods

- (void)displayShow:(NSString *)slug {
    NSDictionary *pluginResultMessage = @{ kVLCPluginJSONTypeKey : kVLCPluginDisplayShowTypeKey,
                                           kVLCPluginDisplayShowSlugKey : slug};
    
    CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:pluginResultMessage];
    [self vlc_sendPluginResult:pluginResult callbackId:self.callbackId];
}

- (void)visualPlayerDisplayShow:(NSString *)slug {
    [self displayShow:slug];
}

- (void)audioPlayerDisplayShow:(NSString *)slug {
    [self displayShow:slug];
}

#pragma mark Saved Audio Methods

- (void)getSavedStatusForAudio:(NYPRAudio *)audio {
    NSDictionary *pluginResultMessage = @{ kVLCPluginJSONTypeKey : kVLCPluginIsAudioSaveAudioTypeKey,
                                           kVLCPluginSaveAudioTypeKeyAudio : [audio metadataAsDictionary]};
    
    CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:pluginResultMessage];
    [self vlc_sendPluginResult:pluginResult callbackId:self.callbackId];
}

- (void)audioSavedStatus:(CDVInvokedUrlCommand*)command {
    BOOL isSaved = [command.arguments.lastObject boolValue];
    NSString *audioID = [self audioIDForCommand:command];
    
    if ([audioID isEqualToString:self.audioToBeDisplayed.audioId]) {
        [self displayAudio:self.audioToBeDisplayed saved:isSaved];
        self.audioToBeDisplayed = nil;
    } else if ([audioID isEqualToString:self.audioToBeSaved.audioId]) {
        if (!isSaved) {
            [self setSavedAudio:self.audioToBeSaved];
        }
        self.audioToBeSaved = nil;
    }
}

- (void)displayAudio:(NYPRAudio *)audio saved:(BOOL)isSaved {
    [self.audioPlayerViewController visualPlayerSetAudioSaved:self.audio saved:isSaved];
    [self.discoverAudioPlaybackDelegate audioPlayerSetAudioSaved:self.audio saved:isSaved];
}


- (void)setSavedAudio:(NYPRAudio *)audio {
    NSDictionary *pluginResultMessage = @{ kVLCPluginJSONTypeKey : kVLCPluginSaveAudioTypeKey,
                                           kVLCPluginSaveAudioTypeKeyAudio : [audio metadataAsDictionary]};
    
    CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:pluginResultMessage];
    [self vlc_sendPluginResult:pluginResult callbackId:self.callbackId];
    [self.audioPlayerViewController visualPlayerSetAudioSaved:audio saved:YES];
    [self.discoverAudioPlaybackDelegate audioPlayerSetAudioSaved:audio saved:YES];
}

- (NSString *)audioIDForCommand:(CDVInvokedUrlCommand*)command {
    NSString *audioID = @"";
    if ([command.arguments.firstObject isKindOfClass:[NSNumber class]]) {
      audioID = [command.arguments.firstObject stringValue];
    }
    return  audioID;
}

#pragma mark NYPRAudioPlayerViewControllerDelegate helpers

- (void)playNextDiscoverTrack {
    [self.discoverAudioPlaybackDelegate discoverPlayerNextTrack];
}

@end


