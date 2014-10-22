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

@implementation VLCPlugin

#pragma mark Initialization

BOOL canBecomeFirstResponderImp(id self, SEL _cmd) {
    return YES;
}

void remoteControlReceivedWithEventImp(id self, SEL _cmd, UIEvent * event) {
    
    NSDictionary *dict = [NSDictionary dictionaryWithObjectsAndKeys:
                          [NSNumber numberWithInteger:event.subtype], @"buttonId",
                          nil];
    
    [[NSNotificationCenter defaultCenter]
     postNotificationName:@"RemoteControlEventNotification"
     object:nil
     userInfo:dict];
}

- (void)pluginInitialize
{
    // MainViewController is dynamically generated by 'cordova create', so... 
    // dynamically add UIResponder methods to the MainViewController class to capture remote control events
    
    // what if another plugin does the same thing?
    
    class_addMethod([self.viewController class], @selector(canBecomeFirstResponder), (IMP) canBecomeFirstResponderImp, "c@:");
    class_addMethod([self.viewController class], @selector(remoteControlReceivedWithEvent:), (IMP) remoteControlReceivedWithEventImp, "v@:@");
    if ([[UIApplication sharedApplication] respondsToSelector:@selector(beginReceivingRemoteControlEvents)]){
      [[UIApplication sharedApplication] beginReceivingRemoteControlEvents];
    }
    [self.viewController becomeFirstResponder];
   
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_onRemoteControlEvent:) name:@"RemoteControlEventNotification" object:nil];
    
    // watch for local notification
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_onLocalNotification:) name:CDVLocalNotification object:nil]; // if app is in foreground
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_onUIApplicationDidFinishLaunchingNotification:) name:@"UIApplicationDidFinishLaunchingNotification" object:nil]; // if app is not in foreground or not running

    [AVAudioSession sharedInstance];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_audioRouteChangeListenerCallback:) name:AVAudioSessionRouteChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_audioInterruption:) name:AVAudioSessionInterruptionNotification object:[AVAudioSession sharedInstance]];
    
    [UIDevice currentDevice].batteryMonitoringEnabled=YES; // required to determine if device is charging
    
    [self _create];
    
    NSLog(@"VLC Plugin initialized");
    NSLog(@"VLC Library Version %@", [[VLCLibrary sharedLibrary] version]);
}

- (void)init:(CDVInvokedUrlCommand*)command {
    
    NSLog (@"VLC Plugin init");
    
    CDVPluginResult* pluginResult = nil;
    
    if ( _audio!=nil) {
        
        NSLog(@"sending wakeup audio to js");
        
        NSDictionary * o = @{ @"type" : @"current",
                              @"audio" : _audio};
        
        pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:o];
        
        _audio = nil;
        
    } else {
        pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
    }
    [self _sendPluginResult:pluginResult callbackId:command.callbackId];
}

- (void) _create {
    _mediaplayer = [[VLCMediaPlayer alloc] init];
    _mediaplayer.delegate = self;
}

#pragma mark Cleanup

-(void) _teardown
{
    if (_mediaplayer) {

        if (_mediaplayer.media) {
            [_mediaplayer stop];
        }

        if (_mediaplayer) {
            _mediaplayer = nil;
        }
    }
}

- (void)dispose {
    NSLog(@"VLC Plugin disposing");
    
    [self _teardown];
   
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

-(void)_sendPluginResult:(CDVPluginResult*)result callbackId:(NSString*)callbackId{
    if (_callbackId==nil){
        _callbackId=callbackId;
    }
    
    if (_callbackId!=nil){
        [result setKeepCallbackAsBool:YES]; // keep for later callbacks
        [self.commandDelegate sendPluginResult:result callbackId:_callbackId];
    }
}

#pragma Audio playback commands

- (void)playstream:(CDVInvokedUrlCommand*)command
{
    CDVPluginResult* pluginResult = nil;
    NSDictionary  * params = [command.arguments  objectAtIndex:0];
    NSString* url = [params objectForKey:@"ios"];
    NSDictionary  * info = [command.arguments  objectAtIndex:1];
    
    if ( url && url != (id)[NSNull null] ) {
        if([[CDVReachability reachabilityForInternetConnection] currentReachabilityStatus]!=NotReachable) {
            [self _playstream:url info:info];
            pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
        } else {
            NSLog (@"VLC Plugin internet not reachable");
            pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"no connection"];
        }
    } else {
        NSLog (@"VLC Plugin invalid stream (%@)", url);
        pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"invalid stream url"];
    }
    
    [self _sendPluginResult:pluginResult callbackId:command.callbackId];
}

- (void)_playstream:(NSString*)url info:(NSDictionary*)info {
    NSLog (@"VLC Plugin starting stream (%@)", url);
    
    VLCMediaPlayerState vlcState = _mediaplayer.state;
    VLCMediaState vlcMediaState = _mediaplayer.media.state;
    
    NSLog(@"%@ / %@", VLCMediaPlayerStateToString(vlcState), VLCMediaStateToString(vlcMediaState));
    
    if (!_mediaplayer.media || ![_mediaplayer.media.url isEqual:[NSURL URLWithString:url] ] || vlcState==VLCMediaPlayerStateStopped || vlcState==VLCMediaPlayerStateError) { // no url or new url
        int prebuffer=10000;
        NetworkStatus connectionType = [[CDVReachability reachabilityForInternetConnection] currentReachabilityStatus];
        
        if ( connectionType == ReachableViaWiFi) {
            prebuffer = 5000;
        }

        _mediaplayer.media = [VLCMedia mediaWithURL:[NSURL URLWithString:url]];
        NSMutableDictionary *dictionary = [[NSMutableDictionary alloc] init];
        [dictionary setObject:@(prebuffer) forKey:@"network-caching"];
        [_mediaplayer.media addOptions:dictionary];
    }
    
    [_mediaplayer play];
    [self setMPNowPlayingInfoCenterNowPlayingInfo:info];
}

- (void)playfile:(CDVInvokedUrlCommand*)command
{
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
        NSString* path = [self _getAudioDirectory];
        NSString* fullPathAndFile=[NSString stringWithFormat:@"%@%@",path, file];
        
        if([[NSFileManager defaultManager] fileExistsAtPath:fullPathAndFile]){
            NSLog (@"VLC Plugin playing local file (%@)", fullPathAndFile);
            if (!_mediaplayer.media || ![_mediaplayer.media.url isEqual:[NSURL fileURLWithPath:fullPathAndFile] ]) { // no url or new url
                _mediaplayer.media = [VLCMedia mediaWithURL:[NSURL fileURLWithPath:fullPathAndFile]];
                [_mediaplayer.media addOptions:@{@"start-time": @(position)}];
            } else if(_mediaplayer.state != VLCMediaPlayerStatePaused) {
                [_mediaplayer.media addOptions:@{@"start-time": @(position)}];
            }
            [_mediaplayer play];
            [self setMPNowPlayingInfoCenterNowPlayingInfo:info];
            pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
            
        } else {
            [self playremotefile:command];
        }
        
    }else {
        NSLog (@"VLC Plugin invalid file (%@)", fullFilename);
        pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"invalid local file url"];
    }
    
    if (pluginResult!=nil) {
        [self _sendPluginResult:pluginResult callbackId:command.callbackId];
    }
}

- (void)pause:(CDVInvokedUrlCommand*)command
{
    NSLog (@"VLC Plugin pausing playback");
    if (_mediaplayer.isPlaying) {
        [_mediaplayer pause];
    }
    
    CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
    [self _sendPluginResult:pluginResult callbackId:command.callbackId];
}

- (void)playremotefile:(CDVInvokedUrlCommand*)command
{
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
            if (!_mediaplayer.media || ![_mediaplayer.media.url isEqual:[NSURL URLWithString:url] ] || _mediaplayer.state == VLCMediaPlayerStateStopped) { // no url or new url, or state is stopped (meaning a likely abnormal termination of playback)
                _mediaplayer.media = [VLCMedia mediaWithURL:[NSURL URLWithString:url]];
                [_mediaplayer.media addOptions:@{@"start-time": @(position)}];
            } else if(_mediaplayer.state != VLCMediaPlayerStatePaused) {
                [_mediaplayer.media addOptions:@{@"start-time": @(position)}];
            } else if (position>0) {
                [_mediaplayer.media addOptions:@{@"start-time": @(position-1)}];
            }
            [_mediaplayer play];
            [self setMPNowPlayingInfoCenterNowPlayingInfo:info];
            pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
        } else {
            NSLog (@"VLC Plugin internet not reachable");
            pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"no connection"];
        }
    } else {
        NSLog (@"VLC Plugin invalid remote file (%@)", url);
        pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"invalid remote file url"];
    }
    
    [self _sendPluginResult:pluginResult callbackId:command.callbackId];
}

- (void)seek:(CDVInvokedUrlCommand*)command
{
    CDVPluginResult* pluginResult = nil;
    NSInteger interval = [[command.arguments objectAtIndex:0] integerValue];
    
    if ([_mediaplayer isSeekable]){
        NSLog (@"VLC Plugin seeking to interval (%d)", interval );
        if (interval>0){
            [_mediaplayer jumpForward:(interval/1000)];
        }else{
            [_mediaplayer jumpBackward:(-1*interval/1000)];
        }
        pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
    } else {
        NSLog (@"VLC Plugin current audio not seekable" );
        pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"audio not seekable"];
    }
    
    [self _sendPluginResult:pluginResult callbackId:command.callbackId];
}

- (void)seekto:(CDVInvokedUrlCommand*)command
{
    CDVPluginResult* pluginResult = nil;
    NSInteger position = [[command.arguments objectAtIndex:0] integerValue];
    
    NSLog (@"VLC seeking to position (%d)", position );
    
    if ([_mediaplayer isSeekable]){
        float seconds=(float)position;
        float length=(float)[[_mediaplayer.media length] intValue];
        float percent=seconds / length;
        [_mediaplayer setPosition:percent];
        pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
    }else {
        NSLog (@"VLC Plugin current audio not seekable" );
        pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"audio not seekable"];
    }
    
    [self _sendPluginResult:pluginResult callbackId:command.callbackId];
}

- (void)stop:(CDVInvokedUrlCommand*)command
{
    CDVPluginResult* pluginResult = nil;

    NSLog (@"VLC Plugin stopping playback.");
    if (_mediaplayer.isPlaying) {
        [_mediaplayer stop];
    }
    
    pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
    [self _sendPluginResult:pluginResult callbackId:command.callbackId];
}

- (void)setaudioinfo:(CDVInvokedUrlCommand*)command{
    NSDictionary  * info = [command.arguments  objectAtIndex:0];
    [self setMPNowPlayingInfoCenterNowPlayingInfo:info];
}

#pragma mark Audio playback helper functions

- (void)getaudiostate:(CDVInvokedUrlCommand*)command
{
    CDVPluginResult* pluginResult = nil;
    
    NSLog (@"VLC Plugin getting audio state");
    
    //[self _createAudioHandler];
    //[self->mAudioHandler getAudioState];
    
    pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
    [self _sendPluginResult:pluginResult callbackId:command.callbackId];
}

- (NSString*)_getAudioDirectory{
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documentsDirectory = [paths objectAtIndex:0];
    NSString *path = [NSString stringWithFormat:@"%@/Audio/",documentsDirectory];
    return path;
}

#pragma mark Audio playback event handlers

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    if ( [keyPath isEqualToString:@"time"] ){
        NSLog(@"observeValueForKeyPath %d/%d", [[_mediaplayer time]intValue], [[_mediaplayer remainingTime]intValue]);
    } else {
        NSLog(@"unknown key observed: %@", keyPath);
    }
}

- (void)mediaPlayerTimeChanged:(NSNotification *)aNotification {
    [self _onAudioProgressUpdate:[[_mediaplayer time]intValue] duration:[[_mediaplayer.media length] intValue] available:-1];
    //NSLog(@"mediaPlayerTimeChanged %d/%d/%d", [[_mediaplayer time]intValue], [[_mediaplayer remainingTime]intValue], [[_mediaplayer.media length] intValue]);
}

- (void)mediaPlayerStateChanged:(NSNotification *)aNotification
{
    VLCMediaPlayerState vlcState = _mediaplayer.state;
    VLCMediaState vlcMediaState = _mediaplayer.media.state;
    
    NSString * description=@"";
    int state = MEDIA_NONE;
    
    NSLog(@"State Change: %@ / %@", VLCMediaPlayerStateToString(vlcState), VLCMediaStateToString(vlcMediaState));
    
    [self _clearFlushBufferTimer];

    switch (vlcState) {
        case VLCMediaPlayerStateStopped:       //< Player has stopped
            state = MEDIA_STOPPED;
            description = @"MEDIA_STOPPED";
            if (_mediaplayer) {
                NSLog(@"audio stopped. times: %d/%d", [[_mediaplayer time]intValue], [[_mediaplayer remainingTime]intValue]);
                if (_mediaplayer.media ) {
                    NSLog(@"length: %d", [[_mediaplayer.media length] intValue]);
                    // regard track as completed if it ends within 1/2 second of length...
                    if ([[_mediaplayer.media length] intValue]>0 && [[_mediaplayer remainingTime]intValue]>=-500 ) {
                        // send final progress update -- the delegate function (mediaPlayerTimeChanged) doesn't seem to fire
                        // for length:length -- the final call to it is for a time less than the track time, so simulate it here...
                        [self _onAudioProgressUpdate:[[_mediaplayer.media length]intValue] duration:[[_mediaplayer.media length] intValue] available:-1];
                        // send complete event
                        [self _onAudioStreamUpdate:MEDIA_COMPLETED description:@"MEDIA_COMPLETED"];
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
            [self _setFlushBufferTimer];
            break;
        default:
            state = MEDIA_NONE;
            description = @"MEDIA_NONE";
            break;
    };
    
    [self _onAudioStreamUpdate:state description:description];
    
    if ([UIDevice currentDevice].batteryState == UIDeviceBatteryStateCharging || [UIDevice currentDevice].batteryState == UIDeviceBatteryStateFull ) {
        // device is charging - disable automatic screen-locking
        [UIApplication sharedApplication].idleTimerDisabled = YES;
    } else {
        // VLC disables the idle timer which controls automatic screen-locking whenever audio/video is playing. re-enable it here, since we are playing audio and disabling automatic
        // screen-locking is more appropriate for video.
        [UIApplication sharedApplication].idleTimerDisabled = NO;
    }
}

- (void) _onAudioStreamUpdate:(int)state description:(NSString*)description
{
    NSLog(@"Posting State Change: %@", description);
    
    NSDictionary * o = @{ @"type" : @"state", @"state" : [NSNumber numberWithInt:state], @"description" : description };
    CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:o];
    [self _sendPluginResult:pluginResult callbackId:_callbackId];
    
    [self setMPNowPlayingInfoCenterNowPlayingInfo:nil];
}

- (void) _onAudioProgressUpdate:(long) progress duration:(long)duration available:(long)available
{
    NSDictionary * o = @{ @"type" : @"progress",
                          @"progress" : [NSNumber numberWithInt:progress] ,
                          @"duration" : [NSNumber numberWithInt:duration],
                          @"available" : [NSNumber numberWithInt:available]};
    
    CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:o];
    [self _sendPluginResult:pluginResult callbackId:_callbackId];
    
    [self setMPNowPlayingInfoCenterNowPlayingInfo:nil];
}

- (void) _onAudioSkipNext
{
    NSDictionary * o = @{ @"type" : @"next" };
    CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:o];
    [self _sendPluginResult:pluginResult callbackId:_callbackId];
}

- (void) _onAudioSkipPrevious
{
    NSDictionary * o = @{ @"type" : @"previous" };
    CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:o];
    [self _sendPluginResult:pluginResult callbackId:_callbackId];
}

- (void) _onRemoteControlEvent:(NSNotification *) notification
{
    if ([[notification name] isEqualToString:@"RemoteControlEventNotification"]){
        NSDictionary *dict = [notification userInfo];
        NSNumber * buttonId = [dict objectForKey:(@"buttonId")];
        
        switch ([buttonId intValue]){
            case UIEventSubtypeRemoteControlTogglePlayPause:
                NSLog(@"Remote control toggle play/pause!");
                if (_mediaplayer.isPlaying){
                    [_mediaplayer pause];
                }else{
                    [_mediaplayer play];
                }
                break;
                
            case UIEventSubtypeRemoteControlPlay:
                NSLog(@"Remote control play!");
                [_mediaplayer play];
                break;
                
            case UIEventSubtypeRemoteControlPause:
                NSLog(@"Remote control toggle pause!");
                [_mediaplayer pause];
                break;
                
            case UIEventSubtypeRemoteControlStop:
                NSLog(@"Remote control stop!");
                [_mediaplayer pause];
                break;
                
            case UIEventSubtypeRemoteControlNextTrack:
                NSLog(@"Remote control next track");
                [self _onAudioSkipNext];
                
                break;
                
            case UIEventSubtypeRemoteControlPreviousTrack:
                NSLog(@"Remote control previous track!");
                [self _onAudioSkipPrevious];
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

NSString* VLCMediaStateToString(VLCMediaState state){
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

- (void) _setFlushBufferTimer {
    _flushBufferTimer = [NSTimer scheduledTimerWithTimeInterval: 60
                                              target: self
                                            selector: @selector(_flushBuffer)
                                            userInfo: nil
                                             repeats: NO];
}

- (void) _flushBuffer {
    NSLog(@"Flushing buffer....");
    [_mediaplayer stop];
}

- (void) _clearFlushBufferTimer {
    [_flushBufferTimer invalidate];
}

#pragma mark Lock Screen Metadata

- (void) setMPNowPlayingInfoCenterNowPlayingInfo:(NSDictionary*)info {
    MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo = [self MPNowPlayingInfoCenterNowPlayingInfo:info];
}

- (NSDictionary*) MPNowPlayingInfoCenterNowPlayingInfo:(NSDictionary*)info {
    NSMutableDictionary *nowPlaying = [MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo mutableCopy];
    if (nowPlaying==nil) {
        nowPlaying = [NSMutableDictionary dictionaryWithCapacity:10];
    }
    
    float _elapsedPlaybackTime = _mediaplayer ? ([[_mediaplayer time]intValue] / 1000): 0.0f;
    NSNumber* elapsedPlaybackTime = @(_elapsedPlaybackTime);
    nowPlaying[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsedPlaybackTime;

    float _playbackDuration = (_mediaplayer && _mediaplayer.media) ? ([[_mediaplayer.media length]intValue]/1000) : 0.0f;
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
            [self performSelectorInBackground:@selector(loadLockscreenImage:) withObject:url]; // load in background to avoid screen lag
        }
        
        if ([info objectForKey:@"lockscreen-art"]!=nil) {
            nowPlaying[MPMediaItemPropertyArtwork] = [info objectForKey:@"lockscreen-art"];
        }
        
    }
    return nowPlaying;
}

- (void)loadLockscreenImage:(NSString*)artwork
{
    if ( [[CDVReachability reachabilityForInternetConnection] currentReachabilityStatus] != NotReachable) {
        NSLog(@"Retrieving lock screen art...");
        NSData *data = [NSData dataWithContentsOfURL:[NSURL URLWithString:artwork]];
        UIImage *img = [[UIImage alloc] initWithData:data];
        if (img){
            NSLog(@"Creating MPMediaItemArtwork...");
            MPMediaItemArtwork * art = [[MPMediaItemArtwork alloc] initWithImage: img];
            [self setMPNowPlayingInfoCenterNowPlayingInfo:@{@"lockscreen-art": art}];
        }
        NSLog(@"Done retrieving lock screen art.");
    }else{
        NSLog(@"Offline - not retrieving lock screen art");
    }
}

#pragma mark Wakeup handlers

- (void)_onLocalNotification:(NSNotification *)notification
{
    NSLog(@"VLC Plugin received local notification while app is running");
    
    UILocalNotification* localNotification = [notification object];
    
    [self _playStreamFromLocalNotification:localNotification];
}


-(void)_onUIApplicationDidFinishLaunchingNotification:(NSNotification*)notification {
    
    NSDictionary *userInfo = [notification userInfo] ;
    UILocalNotification *localNotification = [userInfo objectForKey: @"UIApplicationLaunchOptionsLocalNotificationKey"];
    if (localNotification) {
        [self _playStreamFromLocalNotification:localNotification];
    }
}

-(void)_playStreamFromLocalNotification:(UILocalNotification*)localNotification {
    NSString * notificationType = [[localNotification userInfo] objectForKey:@"type"];
    
    if ( notificationType!=nil && [notificationType isEqualToString:@"wakeup"]) {
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
                        [self _playstream:url info:info];
                    
                        if (_callbackId!=nil && audio!=nil) {
                            NSDictionary * o = @{ @"type" : @"current",
                                                @"audio" : audio};
                        
                            CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:o];
                            [self _sendPluginResult:pluginResult callbackId:_callbackId];
                        
                            _audio = nil;
                        } else {
                            _audio = audio; // send this when callback is available
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
                _mediaplayer.media = [VLCMedia mediaWithURL:url];
                [_mediaplayer play];
            }
        }
    }
}

#pragma mark Headphone handler
- (void)_audioRouteChangeListenerCallback:(NSNotification*)notification
{
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
            if([_mediaplayer isPlaying]) {
                [_mediaplayer pause];
            }
            break;
            
        case AVAudioSessionRouteChangeReasonCategoryChange:
            // called at start - also when other audio wants to play
            NSLog(@"AVAudioSessionRouteChangeReasonCategoryChange");
            break;
    }
}

- (void)_audioInterruption:(NSNotification*)notification
{
    AVAudioSessionInterruptionType interruptionType = [[[notification userInfo] objectForKey:AVAudioSessionInterruptionTypeKey] unsignedIntegerValue];
    if (AVAudioSessionInterruptionTypeBegan == interruptionType) {
        [_mediaplayer pause];
    }else if (AVAudioSessionInterruptionTypeEnded == interruptionType){
    }
}

@end


