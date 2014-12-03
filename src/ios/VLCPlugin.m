//
//  VLCPlugin.m
//
//  Created by Bradford Kammin on 4/2/14.
//
//
#import <AVFoundation/AVFoundation.h>
#import <MediaPlayer/MediaPlayer.h>
#include <objc/runtime.h>
#import "CDVSound.h"
#import "CDVReachability.h"
#import "VLCPlugin.h"

enum NYPRExtraMediaStates {
    MEDIA_LOADING = MEDIA_STOPPED + 1,
    MEDIA_COMPLETED = MEDIA_STOPPED + 2,
    MEDIA_PAUSING = MEDIA_STOPPED + 3,
    MEDIA_STOPPING = MEDIA_STOPPED + 4
};
typedef NSUInteger NYPRExtraMediaStates;

@interface VLCPlugin ()

@property VLCMediaPlayer * mediaPlayer;
@property NSString * callbackId;
@property NSDictionary * currentAudio;
@property NSTimer * flushBufferTimer;
@property NSDictionary * lockScreenCache;

@end

@implementation VLCPlugin

#pragma mark Initialization

- (void)pluginInitialize {

    // turn on remote control
   if ([[UIApplication sharedApplication] respondsToSelector:@selector(beginReceivingRemoteControlEvents)]){
      [[UIApplication sharedApplication] beginReceivingRemoteControlEvents];
    }
    [self.viewController becomeFirstResponder];
   
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(vlc_onRemoteControlEvent:) name:@"RemoteControlEventNotification" object:nil];
    
    // watch for local notification
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(vlc_onLocalNotification:) name:CDVLocalNotification object:nil]; // if app is in foreground
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(vlc_onUIApplicationDidFinishLaunchingNotification:) name:@"UIApplicationDidFinishLaunchingNotification" object:nil]; // if app is not in foreground or not running

    [AVAudioSession sharedInstance];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(vlc_audioRouteChangeListenerCallback:) name:AVAudioSessionRouteChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(vlc_audioInterruption:) name:AVAudioSessionInterruptionNotification object:[AVAudioSession sharedInstance]];
    
    [UIDevice currentDevice].batteryMonitoringEnabled=YES; // required to determine if device is charging
    
    [self vlc_create];
    
    NSLog(@"VLC Plugin initialized");
    NSLog(@"VLC Library Version %@", [[VLCLibrary sharedLibrary] version]);
}

- (void)init:(CDVInvokedUrlCommand*)command {
    
    NSLog (@"VLC Plugin init");
    
    CDVPluginResult* pluginResult = nil;
    
    if ( _currentAudio!=nil) {
        
        NSLog(@"sending wakeup audio to js");
        
        NSDictionary * o = @{ @"type" : @"current",
                              @"audio" : _currentAudio};
        
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
    NSLog(@"VLC Plugin disposing");
    
    [self vlc_teardown];
   
    [[NSNotificationCenter defaultCenter] removeObserver:self name:CDVLocalNotification object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:@"UIApplicationDidFinishLaunchingNotification" object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:@"RemoteControlEventNotification" object:nil];
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

- (void)playstream:(CDVInvokedUrlCommand*)command {
    CDVPluginResult* pluginResult = nil;
    NSDictionary  * params = [command.arguments  objectAtIndex:0];
    NSString* url = [params objectForKey:@"ios"];
    NSDictionary  * info = [command.arguments  objectAtIndex:1];
    
    if ( url && url != (id)[NSNull null] ) {
        if([[CDVReachability reachabilityForInternetConnection] currentReachabilityStatus]!=NotReachable) {
            [self vlc_playstream:url info:info];
            pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
        } else {
            NSLog (@"VLC Plugin internet not reachable");
            pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"no connection"];
        }
    } else {
        NSLog (@"VLC Plugin invalid stream (%@)", url);
        pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"invalid stream url"];
    }
    
    [self vlc_sendPluginResult:pluginResult callbackId:command.callbackId];
}

- (void)vlc_playstream:(NSString*)url info:(NSDictionary*)info {
    NSLog (@"VLC Plugin starting stream (%@)", url);
    
    VLCMediaPlayerState vlcState = self.mediaPlayer.state;
    VLCMediaState vlcMediaState = self.mediaPlayer.media.state;
    
    NSLog(@"%@ / %@", VLCMediaPlayerStateToString(vlcState), vlc_convertVLCMediaStateToString(vlcMediaState));
    
    if (!self.mediaPlayer.media || ![self.mediaPlayer.media.url isEqual:[NSURL URLWithString:url] ] || vlcState==VLCMediaPlayerStateStopped || vlcState==VLCMediaPlayerStateError) { // no url or new url
        if(self.mediaPlayer.state == VLCMediaPlayerStatePaused) {
            // hack to fix WNYCAPP-1031 -- audio of new track is not playing if new track is played while current track is paused
            // better solution is to 'stop' current track/stream and wait for stopped event before playing, so current and new tracks don't step on each other in weird ways
            [self.mediaPlayer stop];
        }
        
        int prebuffer=10000;
        NetworkStatus connectionType = [[CDVReachability reachabilityForInternetConnection] currentReachabilityStatus];
        
        if ( connectionType == ReachableViaWiFi) {
            prebuffer = 5000;
        }

        self.mediaPlayer.media = [VLCMedia mediaWithURL:[NSURL URLWithString:url]];
        NSMutableDictionary *dictionary = [[NSMutableDictionary alloc] init];
        [dictionary setObject:@(prebuffer) forKey:@"network-caching"];
        [self.mediaPlayer.media addOptions:dictionary];
        
    }
    [self.mediaPlayer play];
    [self vlc_setlockscreenmetadata:info refreshLockScreen:false];
}

- (void)playfile:(CDVInvokedUrlCommand*)command {
    CDVPluginResult* pluginResult = nil;
    NSString* fullFilename = [command.arguments objectAtIndex:0];
    NSDictionary  * info = [command.arguments  objectAtIndex:1];
    NSInteger position = 0;
    
    if ( command.arguments.count > 2 && [command.arguments objectAtIndex:2] != (id)[NSNull null] ) {
        position = [[command.arguments objectAtIndex:2] integerValue];
    }
    
    if ( fullFilename && fullFilename != (id)[NSNull null] ) {
        
        // get the filename at the end of the file
        NSString *file = [[[NSURL URLWithString:fullFilename]  lastPathComponent] lowercaseString];
        NSString* path = [self vlc_getAudioDirectory];
        NSString* fullPathAndFile=[NSString stringWithFormat:@"%@%@",path, file];
        
        if([[NSFileManager defaultManager] fileExistsAtPath:fullPathAndFile]){
            NSLog (@"VLC Plugin playing local file (%@)", fullPathAndFile);
            if (!self.mediaPlayer.media || ![self.mediaPlayer.media.url isEqual:[NSURL fileURLWithPath:fullPathAndFile] ]) { // no url or new url
                if(self.mediaPlayer.state == VLCMediaPlayerStatePaused) {
                    // hack to fix WNYCAPP-1031 -- audio of new track is not playing if new track is played while current track is paused
                    // better solution is to 'stop' current track/stream and wait for stopped event before playing, so current and new tracks don't step on each other in weird ways
                    [self.mediaPlayer stop];
                }
                self.mediaPlayer.media = [VLCMedia mediaWithURL:[NSURL fileURLWithPath:fullPathAndFile]];
                [self.mediaPlayer.media addOptions:@{@"start-time": @(position)}];
            } else if(self.mediaPlayer.state != VLCMediaPlayerStatePaused) {
                [self.mediaPlayer.media addOptions:@{@"start-time": @(position)}];
            }
            [self.mediaPlayer play];
            [self vlc_setlockscreenmetadata:info refreshLockScreen:false];
            pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
            
        } else {
            [self playremotefile:command];
        }
        
    }else {
        NSLog (@"VLC Plugin invalid file (%@)", fullFilename);
        pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"invalid local file url"];
    }
    
    if (pluginResult!=nil) {
        [self vlc_sendPluginResult:pluginResult callbackId:command.callbackId];
    }
}

- (void)playremotefile:(CDVInvokedUrlCommand*)command {
    CDVPluginResult* pluginResult = nil;
    
    NSString* url = [command.arguments objectAtIndex:0];
    NSDictionary  * info = [command.arguments  objectAtIndex:1];
    NSInteger position = 0;
    
    if (command.arguments.count>2 && [command.arguments objectAtIndex:2] != (id)[NSNull null]) {
        position = [[command.arguments objectAtIndex:2] integerValue];
    }
    
    if ( url && url != (id)[NSNull null] ) {
        if([[CDVReachability reachabilityForInternetConnection] currentReachabilityStatus]!=NotReachable) {
            NSLog (@"VLC Plugin playing remote file (%@)", url);
            if (!self.mediaPlayer.media || ![self.mediaPlayer.media.url isEqual:[NSURL URLWithString:url] ] || self.mediaPlayer.state == VLCMediaPlayerStateStopped) { // no url or new url, or state is stopped (meaning a likely abnormal termination of playback)
                if(self.mediaPlayer.state == VLCMediaPlayerStatePaused) {
                    // hack to fix WNYCAPP-1031 -- audio of new track is not playing if new track is played while current track is paused
                    // better solution is to 'stop' current track/stream and wait for stopped event before playing, so current and new tracks don't step on each other in weird ways
                    [self.mediaPlayer stop];
                }
                self.mediaPlayer.media = [VLCMedia mediaWithURL:[NSURL URLWithString:url]];
                [self.mediaPlayer.media addOptions:@{@"start-time": @(position)}];
            } else if(self.mediaPlayer.state != VLCMediaPlayerStatePaused) {
                [self.mediaPlayer.media addOptions:@{@"start-time": @(position)}];
            } else if (position>0) {
                [self.mediaPlayer.media addOptions:@{@"start-time": @(position-1)}];
            }
            [self.mediaPlayer play];
            [self vlc_setlockscreenmetadata:info refreshLockScreen:false];
            pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
        } else {
            NSLog (@"VLC Plugin internet not reachable");
            pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"no connection"];
        }
    } else {
        NSLog (@"VLC Plugin invalid remote file (%@)", url);
        pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"invalid remote file url"];
    }
    
    [self vlc_sendPluginResult:pluginResult callbackId:command.callbackId];
}

- (void)pause:(CDVInvokedUrlCommand*)command {
    NSLog (@"VLC Plugin pausing playback");
    if (self.mediaPlayer.isPlaying) {
        [self.mediaPlayer pause];
    }
    
    CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
    [self vlc_sendPluginResult:pluginResult callbackId:command.callbackId];
}

- (void)seek:(CDVInvokedUrlCommand*)command {
    CDVPluginResult* pluginResult = nil;
    NSInteger interval = [[command.arguments objectAtIndex:0] integerValue];
    
    if ([self.mediaPlayer isSeekable]){
        NSLog (@"VLC Plugin seeking to interval (%ld)", (long)interval );
        if (interval>0){
            [self.mediaPlayer jumpForward:((int)interval/1000)];
        }else{
            [self.mediaPlayer jumpBackward:(-1*(int)interval/1000)];
        }
        pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
    } else {
        NSLog (@"VLC Plugin current audio not seekable" );
        pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"audio not seekable"];
    }
    
    [self vlc_sendPluginResult:pluginResult callbackId:command.callbackId];
}

- (void)seekto:(CDVInvokedUrlCommand*)command {
    CDVPluginResult* pluginResult = nil;
    NSInteger position = [[command.arguments objectAtIndex:0] integerValue];
    
    NSLog (@"VLC seeking to position (%ld)", (long)position );
    
    if ([self.mediaPlayer isSeekable]){
        float seconds=(float)position;
        float length=(float)[[self.mediaPlayer.media length] intValue];
        float percent=seconds / length;
        [self.mediaPlayer setPosition:percent];
        pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
    }else {
        NSLog (@"VLC Plugin current audio not seekable" );
        pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"audio not seekable"];
    }
    
    [self vlc_sendPluginResult:pluginResult callbackId:command.callbackId];
}

- (void)stop:(CDVInvokedUrlCommand*)command {
    CDVPluginResult* pluginResult = nil;

    NSLog (@"VLC Plugin stopping playback.");
    if (self.mediaPlayer.isPlaying) {
        [self.mediaPlayer stop];
    }
    
    pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
    [self vlc_sendPluginResult:pluginResult callbackId:command.callbackId];
}

- (void)setaudioinfo:(CDVInvokedUrlCommand*)command{
    NSDictionary  * info = [command.arguments  objectAtIndex:0];
    [self vlc_setlockscreenmetadata:info refreshLockScreen:true];
}

- (void)vlc_setlockscreenmetadata:(NSDictionary*)metadata refreshLockScreen:(BOOL)refreshLockScreen {
    self.lockScreenCache = [NSDictionary dictionaryWithDictionary:metadata];
    if(refreshLockScreen){
        [self vlc_setMPNowPlayingInfoCenterNowPlayingInfo:self.lockScreenCache];
    }
}

#pragma mark Audio playback helper functions

- (NSString*)vlc_getAudioDirectory{
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documentsDirectory = [paths objectAtIndex:0];
    NSString *path = [NSString stringWithFormat:@"%@/Audio/",documentsDirectory];
    return path;
}

#pragma mark Audio playback event handlers

- (void)mediaPlayerTimeChanged:(NSNotification *)aNotification {
    [self vlc_onAudioProgressUpdate:[[self.mediaPlayer time]intValue] duration:[[self.mediaPlayer.media length] intValue] available:-1];
    //NSLog(@"mediaPlayerTimeChanged %d/%d/%d", [[self.mediaPlayer time]intValue], [[self.mediaPlayer remainingTime]intValue], [[self.mediaPlayer.media length] intValue]);
}

- (void)mediaPlayerStateChanged:(NSNotification *)aNotification {
    VLCMediaPlayerState vlcState = self.mediaPlayer.state;
    VLCMediaState vlcMediaState = self.mediaPlayer.media.state;
    
    NSString * description=@"";
    int state = MEDIA_NONE;
    
    NSLog(@"State Change: %@ / %@", VLCMediaPlayerStateToString(vlcState), vlc_convertVLCMediaStateToString(vlcMediaState));
    
    [self vlc_clearFlushBufferTimer];

    switch (vlcState) {
        case VLCMediaPlayerStateStopped:       //< Player has stopped
            state = MEDIA_STOPPED;
            description = @"MEDIA_STOPPED";
            if (self.mediaPlayer) {
                NSLog(@"audio stopped. times: %d/%d", [[self.mediaPlayer time]intValue], [[self.mediaPlayer remainingTime]intValue]);
                if (self.mediaPlayer.media ) {
                    NSLog(@"length: %d", [[self.mediaPlayer.media length] intValue]);
                    // regard track as completed if it ends within 1/2 second of length...
                    if ([[self.mediaPlayer.media length] intValue]>0 && [[self.mediaPlayer remainingTime]intValue]>=-500 ) {
                        // send final progress update -- the delegate function (mediaPlayerTimeChanged) doesn't seem to fire
                        // for length:length -- the final call to it is for a time less than the track time, so simulate it here...
                        [self vlc_onAudioProgressUpdate:[[self.mediaPlayer.media length]intValue] duration:[[self.mediaPlayer.media length] intValue] available:-1];
                        // send complete event
                        [self vlc_onAudioStreamUpdate:MEDIA_COMPLETED description:@"MEDIA_COMPLETED"];
                    }
                }
            }
            break;
        case VLCMediaPlayerStateOpening:        //< Stream is opening
            state = MEDIA_STARTING;
            description = @"MEDIA_STARTING";
            break;
        case VLCMediaPlayerStateBuffering:      //< Stream is buffering
            if ( vlcMediaState == VLCMediaStatePlaying ) {
                state = MEDIA_RUNNING;
                description = @"MEDIA_RUNNING";
            } else {
                state = MEDIA_STARTING;
                description = @"MEDIA_STARTING";
            }
            break;
        case VLCMediaPlayerStateEnded:          //< Stream has ended
            state = MEDIA_COMPLETED;
            description = @"MEDIA_COMPLETED";
            break;
        case VLCMediaPlayerStateError:          //< Player has generated an error
            state = MEDIA_STOPPED;
            description = @"MEDIA_STOPPED";
            break;
        case VLCMediaPlayerStatePlaying:        //< Stream is playing
            state = MEDIA_RUNNING;
            description = @"MEDIA_RUNNING";
            break;
        case VLCMediaPlayerStatePaused:          //< Stream is paused
            state = MEDIA_PAUSED;
            description = @"MEDIA_PAUSED";
            [self vlc_setFlushBufferTimer];
            break;
        default:
            state = MEDIA_NONE;
            description = @"MEDIA_NONE";
            break;
    };
    
    if(state==MEDIA_RUNNING) {
        [self vlc_setMPNowPlayingInfoCenterNowPlayingInfo:self.lockScreenCache];
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

- (void) vlc_onAudioStreamUpdate:(int)state description:(NSString*)description {
    NSLog(@"Posting State Change: %@", description);
    
    NSDictionary * o = @{ @"type" : @"state", @"state" : [NSNumber numberWithInt:state], @"description" : description };
    CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:o];
    [self vlc_sendPluginResult:pluginResult callbackId:self.callbackId];
    
    [self vlc_setMPNowPlayingInfoCenterNowPlayingInfo:nil];
}

- (void) vlc_onAudioProgressUpdate:(long) progress duration:(long)duration available:(long)available {
    NSDictionary * o = @{ @"type" : @"progress",
                          @"progress" : [NSNumber numberWithInt:(int)progress] ,
                          @"duration" : [NSNumber numberWithInt:(int)duration],
                          @"available" : [NSNumber numberWithInt:(int)available]};
    
    CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:o];
    [self vlc_sendPluginResult:pluginResult callbackId:self.callbackId];
    
    [self vlc_setMPNowPlayingInfoCenterNowPlayingInfo:nil];
}

- (void) vlc_onAudioSkipNext {
    NSDictionary * o = @{ @"type" : @"next" };
    CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:o];
    [self vlc_sendPluginResult:pluginResult callbackId:self.callbackId];
}

- (void) vlc_onAudioSkipPrevious {
    NSDictionary * o = @{ @"type" : @"previous" };
    CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:o];
    [self vlc_sendPluginResult:pluginResult callbackId:self.callbackId];
}

- (void) vlc_onRemoteControlEvent:(NSNotification *) notification {
    if ([[notification name] isEqualToString:@"RemoteControlEventNotification"]){
        NSDictionary *dict = [notification userInfo];
        NSNumber * buttonId = [dict objectForKey:(@"buttonId")];
        
        switch ([buttonId intValue]){
            case UIEventSubtypeRemoteControlTogglePlayPause:
                NSLog(@"Remote control toggle play/pause!");
                if (self.mediaPlayer.isPlaying){
                    [self.mediaPlayer pause];
                }else{
                    [self.mediaPlayer play];
                }
                break;
                
            case UIEventSubtypeRemoteControlPlay:
                NSLog(@"Remote control play!");
                [self.mediaPlayer play];
                break;
                
            case UIEventSubtypeRemoteControlPause:
                NSLog(@"Remote control toggle pause!");
                [self.mediaPlayer pause];
                break;
                
            case UIEventSubtypeRemoteControlStop:
                NSLog(@"Remote control stop!");
                [self.mediaPlayer pause];
                break;
                
            case UIEventSubtypeRemoteControlNextTrack:
                NSLog(@"Remote control next track");
                [self vlc_onAudioSkipNext];
                
                break;
                
            case UIEventSubtypeRemoteControlPreviousTrack:
                NSLog(@"Remote control previous track!");
                [self vlc_onAudioSkipPrevious];
                break;
                
            case UIEventSubtypeRemoteControlBeginSeekingBackward:
                NSLog(@"Remote control begin seeking backward!");
                break;
                
            case UIEventSubtypeRemoteControlEndSeekingBackward:
                NSLog(@"Remote control end seeking backward!");
                break;
                
            case UIEventSubtypeRemoteControlBeginSeekingForward:
                NSLog(@"Remote control begin seeking forward!");
                break;
                
            case UIEventSubtypeRemoteControlEndSeekingForward:
                NSLog(@"Remote control end seeking forward!");
                
                break;
                
            default:
                
                NSLog(@"Remote control unknown!");
                break;
        }
    }
}

#pragma mark Misc

NSString* vlc_convertVLCMediaStateToString(VLCMediaState state){
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

- (void) vlc_setFlushBufferTimer {
    self.flushBufferTimer = [NSTimer scheduledTimerWithTimeInterval: 60
                                              target: self
                                            selector: @selector(vlc_flushBuffer)
                                            userInfo: nil
                                             repeats: NO];
}

- (void) vlc_flushBuffer {
    NSLog(@"Flushing buffer....");
    [self.mediaPlayer stop];
}

- (void) vlc_clearFlushBufferTimer {
    [self.flushBufferTimer invalidate];
}

#pragma mark Lock Screen Metadata

- (void) vlc_setMPNowPlayingInfoCenterNowPlayingInfo:(NSDictionary*)info {
    MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo = [self vlc_configureNowPlayingInfoCenterNowPlayingInfo:info];
}

- (NSDictionary*) vlc_configureNowPlayingInfoCenterNowPlayingInfo:(NSDictionary*)info {
    NSMutableDictionary *nowPlaying = [MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo mutableCopy];
    if (nowPlaying==nil) {
        nowPlaying = [NSMutableDictionary dictionaryWithCapacity:10];
    }
    
    float _elapsedPlaybackTime = self.mediaPlayer ? ([[self.mediaPlayer time]intValue] / 1000): 0.0f;
    NSNumber* elapsedPlaybackTime = @(_elapsedPlaybackTime);
    nowPlaying[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsedPlaybackTime;

    float _playbackDuration = (self.mediaPlayer && self.mediaPlayer.media) ? ([[self.mediaPlayer.media length]intValue]/1000) : 0.0f;
    if (_playbackDuration==0.0f){
        _playbackDuration=_elapsedPlaybackTime;
    }
    NSNumber* playbackDuration = @(_playbackDuration);
    nowPlaying[MPMediaItemPropertyPlaybackDuration] = playbackDuration;
    
    if (info!=nil) {
        if ([info objectForKey:@"title"]!=nil) {
            nowPlaying[MPMediaItemPropertyTitle] = [info objectForKey:@"title"];
        }
        
        if ([info objectForKey:@"artist"]!=nil) {
            nowPlaying[MPMediaItemPropertyArtist] = [info objectForKey:@"artist"];
        }
        
        NSDictionary * artwork = [info objectForKey:@"image"];
        if (artwork && artwork != (id)[NSNull null] && [artwork objectForKey:@"url"] != nil){
            NSString * url = [artwork objectForKey:@"url"];
            [self performSelectorInBackground:@selector(vlc_loadLockscreenImage:) withObject:url]; // load in background to avoid screen lag
        }
        
        if ([info objectForKey:@"lockscreen-art"]!=nil) {
            nowPlaying[MPMediaItemPropertyArtwork] = [info objectForKey:@"lockscreen-art"];
        }
        
    }
    return nowPlaying;
}

- (void)vlc_loadLockscreenImage:(NSString*)artwork {
    if ( [[CDVReachability reachabilityForInternetConnection] currentReachabilityStatus] != NotReachable) {
        NSLog(@"Retrieving lock screen art...");
        NSData *data = [NSData dataWithContentsOfURL:[NSURL URLWithString:artwork]];
        UIImage *img = [[UIImage alloc] initWithData:data];
        if (img){
            NSLog(@"Creating MPMediaItemArtwork...");
            MPMediaItemArtwork * art = [[MPMediaItemArtwork alloc] initWithImage: img];
            [self vlc_setMPNowPlayingInfoCenterNowPlayingInfo:@{@"lockscreen-art": art}];
        }
        NSLog(@"Done retrieving lock screen art.");
    }else{
        NSLog(@"Offline - not retrieving lock screen art");
    }
}

#pragma mark Notification handlers

- (void)vlc_onLocalNotification:(NSNotification *)notification {
    NSLog(@"VLC Plugin received local notification while app is running");
    
    UILocalNotification* localNotification = [notification object];
    
    [self vlc_playStreamFromLocalNotification:localNotification];
}


-(void)vlc_onUIApplicationDidFinishLaunchingNotification:(NSNotification*)notification {
    
    NSDictionary *userInfo = [notification userInfo] ;
    UILocalNotification *localNotification = [userInfo objectForKey: @"UIApplicationLaunchOptionsLocalNotificationKey"];
    if (localNotification) {
        [self vlc_playStreamFromLocalNotification:localNotification];
    }
}

-(void)vlc_playStreamFromLocalNotification:(UILocalNotification*)localNotification {
    NSString * notificationType = [[localNotification userInfo] objectForKey:@"type"];
    
    if ( notificationType!=nil && [notificationType isEqualToString:@"wakeup"]) { // use a better type thatn 'wakeup' here, to decouple from 'wakeup' logic
        NSLog(@"wakeup detected!");
        
        NSString * s = [[localNotification userInfo] objectForKey:@"extra"];
        NSError *error;
        NSData *data = [s dataUsingEncoding:NSUTF8StringEncoding];
        NSDictionary *extra = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
        
        if([[CDVReachability reachabilityForInternetConnection] currentReachabilityStatus]!=NotReachable) {
        
            if (extra!=nil){
                NSDictionary  * streams = [extra objectForKey:@"streams"];
                NSDictionary  * info = [extra objectForKey:@"info"];
                NSDictionary  * audio = [extra objectForKey:@"audio"];
                NSString* url = nil;
            
                if (streams) {
                    url=[streams objectForKey:@"ios"];
                    if (url!=nil) {
                        [self vlc_playstream:url info:info];
                    
                        if (self.callbackId!=nil && audio!=nil) {
                            NSDictionary * o = @{ @"type" : @"current",
                                                @"audio" : audio};
                        
                            CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:o];
                            [self vlc_sendPluginResult:pluginResult callbackId:self.callbackId];
                        
                            self.currentAudio = nil;
                        } else {
                            self.currentAudio = audio; // send this when callback is available
                        }
                    }
                }
            }
        } else {
            NSLog(@"VLC wakeup - cannot play stream due to no connection");
            if (extra!=nil) {
                NSString  * sound = [extra objectForKey:@"offline_sound"];
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
            NSLog(@"AVAudioSessionRouteChangeReasonNewDeviceAvailable");
            NSLog(@"Headphone/Line plugged in");
            break;
            
        case AVAudioSessionRouteChangeReasonOldDeviceUnavailable:
            NSLog(@"AVAudioSessionRouteChangeReasonOldDeviceUnavailable");
            NSLog(@"Headphone/Line was pulled. Stopping player....");
            if([self.mediaPlayer isPlaying]) {
                [self.mediaPlayer pause];
            }
            break;
            
        case AVAudioSessionRouteChangeReasonCategoryChange:
            // called at start - also when other audio wants to play
            NSLog(@"AVAudioSessionRouteChangeReasonCategoryChange");
            break;
    }
}

- (void)vlc_audioInterruption:(NSNotification*)notification {
    AVAudioSessionInterruptionType interruptionType = [[[notification userInfo] objectForKey:AVAudioSessionInterruptionTypeKey] unsignedIntegerValue];
    if (AVAudioSessionInterruptionTypeBegan == interruptionType) {
        [self.mediaPlayer pause];
    }else if (AVAudioSessionInterruptionTypeEnded == interruptionType){
    }
}

@end


