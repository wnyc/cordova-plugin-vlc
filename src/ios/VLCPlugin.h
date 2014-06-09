//
//  VLCPlugin.h
//  NYPRNative
//
//  Created by Bradford Kammin on 4/2/14.
//
//

#import <Cordova/CDVPlugin.h>
#import <Cordova/CDVPluginResult.h>
#import <AVFoundation/AVFoundation.h>
#import <MobileVLCKit/MobileVLCKit.h>

@interface VLCPlugin : CDVPlugin
{
    VLCMediaPlayer *_mediaplayer;
    
    NSString * _callbackId;
    NSDictionary * _audio;
    NSTimer * _flushBufferTimer;
}

- (void)init:(CDVInvokedUrlCommand*)command;
- (void)getaudiostate:(CDVInvokedUrlCommand*)command;
- (void)playstream:(CDVInvokedUrlCommand*)command;
- (void)playremotefile:(CDVInvokedUrlCommand*)command;
- (void)playfile:(CDVInvokedUrlCommand*)command;
- (void)pause:(CDVInvokedUrlCommand*)command;
- (void)stop:(CDVInvokedUrlCommand*)command;
- (void)seek:(CDVInvokedUrlCommand*)command;
- (void)seekto:(CDVInvokedUrlCommand*)command;
- (void)setaudioinfo:(CDVInvokedUrlCommand*)command;

@end
