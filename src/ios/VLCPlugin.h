//
//  VLCPlugin.h
//

#import <Cordova/CDVPlugin.h>
#import <Cordova/CDVPluginResult.h>
#import <AVFoundation/AVFoundation.h>
#import <MobileVLCKit/MobileVLCKit.h>
#import <NYPRDiscoverSDK/NYPRDiscoverSDK.h>

extern NSString * const VLCPluginRemoteControlEventNotification;

@interface VLCPlugin : CDVPlugin <VLCMediaPlayerDelegate, NYPRDiscoverAudioPlayer, NYPRAudioPlayerViewControllerDelegate>

- (void)init:(CDVInvokedUrlCommand*)command;
- (void)playstream:(CDVInvokedUrlCommand*)command;
- (void)playfile:(CDVInvokedUrlCommand*)command;
- (void)pause:(CDVInvokedUrlCommand*)command;
- (void)stop:(CDVInvokedUrlCommand*)command;
- (void)setaudioinfo:(CDVInvokedUrlCommand*)command;
- (void)audioSavedStatus:(CDVInvokedUrlCommand*)command;
- (void)queueCompleted:(CDVInvokedUrlCommand*)command;

@end
