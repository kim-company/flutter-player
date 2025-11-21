// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#import "./include/video_player_avfoundation/FVPTextureBasedVideoPlayer.h"
#import "./include/video_player_avfoundation/FVPTextureBasedVideoPlayer_Test.h"

#import <AVKit/AVKit.h>

API_AVAILABLE(macos(10.15), ios(9.0))
@interface FVPTextureBasedVideoPlayer () <AVPictureInPictureControllerDelegate>
// The updater that drives callbacks to the engine to indicate that a new frame is ready.
@property(nonatomic) FVPFrameUpdater *frameUpdater;
// The display link that drives frameUpdater.
@property(nonatomic) NSObject<FVPDisplayLink> *displayLink;
// The latest buffer obtained from video output. This is stored so that it can be returned from
// copyPixelBuffer again if nothing new is available, since the engine has undefined behavior when
// returning NULL.
@property(nonatomic) CVPixelBufferRef latestPixelBuffer;
// The time that represents when the next frame displays.
@property(nonatomic) CFTimeInterval targetTime;
// Whether to enqueue textureFrameAvailable from copyPixelBuffer.
@property(nonatomic) BOOL selfRefresh;
// The time that represents the start of average frame duration measurement.
@property(nonatomic) CFTimeInterval startTime;
// The number of frames since the start of average frame duration measurement.
@property(nonatomic) int framesCount;
// The latest frame duration since there was significant change.
@property(nonatomic) CFTimeInterval latestDuration;
// Whether a new frame needs to be provided to the engine regardless of the current play/pause state
// (e.g., after a seek while paused). If YES, the display link should continue to run until the next
// frame is successfully provided.
@property(nonatomic, assign) BOOL waitingForFrame;
// The picture-in-picture controller.
@property(nonatomic) AVPictureInPictureController *pictureInPictureController API_AVAILABLE(macos(10.15), ios(9.0));

/// Ensures that the frame updater runs until a frame is rendered, regardless of play/pause state.
- (void)expectFrame;
/// Sets up the picture-in-picture controller.
- (void)setUpPictureInPictureController API_AVAILABLE(macos(10.15), ios(9.0));
@end

@implementation FVPTextureBasedVideoPlayer

- (instancetype)initWithPlayerItem:(AVPlayerItem *)item
                      frameUpdater:(FVPFrameUpdater *)frameUpdater
                       displayLink:(NSObject<FVPDisplayLink> *)displayLink
                         avFactory:(id<FVPAVFactory>)avFactory
                      viewProvider:(NSObject<FVPViewProvider> *)viewProvider {
  self = [super initWithPlayerItem:item avFactory:avFactory viewProvider:viewProvider];

  if (self) {
    _frameUpdater = frameUpdater;
    _displayLink = displayLink;
    _frameUpdater.displayLink = _displayLink;
    _selfRefresh = true;

    // This is to fix 2 bugs: 1. blank video for encrypted video streams on iOS 16
    // (https://github.com/flutter/flutter/issues/111457) and 2. swapped width and height for some
    // video streams (not just iOS 16).  (https://github.com/flutter/flutter/issues/109116). An
    // invisible AVPlayerLayer is used to overwrite the protection of pixel buffers in those streams
    // for issue #1, and restore the correct width and height for issue #2.
    _playerLayer = [AVPlayerLayer playerLayerWithPlayer:self.player];
    // picture-in-picture shows a placeholder where the original video was playing.
    // This is a native overlay that does not scroll with the rest of the Flutter UI.
    // That is why we need to set the opacity of the overlay.
    // Setting it to 0 would result in the picture-in-picture not working.
    // Setting it to 1 would result in the picture-in-picture overlay always showing over other
    // widgets. Setting it to 0.001 makes the placeholder invisible, but still allows the
    // picture-in-picture.
    _playerLayer.opacity = 0.001;
    [viewProvider.view.layer addSublayer:self.playerLayer];

    // Configure Picture in Picture controller
    [self setUpPictureInPictureController];
  }
  return self;
}

- (void)dealloc {
  CVBufferRelease(_latestPixelBuffer);
}

- (void)setTextureIdentifier:(int64_t)textureIdentifier {
  self.frameUpdater.textureIdentifier = textureIdentifier;

  // Ensure that the first frame is drawn once available, even if the video isn't played, since
  // the engine is now expecting the texture to be populated.
  [self expectFrame];
}

- (void)expectFrame {
  self.waitingForFrame = YES;

  _displayLink.running = YES;
}

#pragma mark - Overrides

- (void)updatePlayingState {
  [super updatePlayingState];
  // If the texture is still waiting for an expected frame, the display link needs to keep
  // running until it arrives regardless of the play/pause state.
  _displayLink.running = self.isPlaying || self.waitingForFrame;
}

- (void)seekTo:(NSInteger)position completion:(void (^)(FlutterError *_Nullable))completion {
  CMTime previousCMTime = self.player.currentTime;
  [super seekTo:position
      completion:^(FlutterError *error) {
        if (CMTimeCompare(self.player.currentTime, previousCMTime) != 0) {
          // Ensure that a frame is drawn once available, even if currently paused. In theory a
          // race is possible here where the new frame has already drawn by the time this code
          // runs, and the display link stays on indefinitely, but that should be relatively
          // harmless. This must use the display link rather than just informing the engine that a
          // new frame is available because the seek completing doesn't guarantee that the pixel
          // buffer is already available.
          [self expectFrame];
        }

        if (completion) {
          completion(error);
        }
      }];
}

- (void)disposeWithError:(FlutterError *_Nullable *_Nonnull)error {
  [super disposeWithError:error];

  [self.playerLayer removeFromSuperlayer];

  _displayLink = nil;
}

#pragma mark - FlutterTexture

- (CVPixelBufferRef)copyPixelBuffer {
  // If the difference between target time and current time is longer than this fraction of frame
  // duration then reset target time.
  const float resetThreshold = 0.5;

  // Ensure video sampling at regular intervals. This function is not called at exact time intervals
  // so CACurrentMediaTime returns irregular timestamps which causes missed video frames. The range
  // outside of which targetTime is reset should be narrow enough to make possible lag as small as
  // possible and at the same time wide enough to avoid too frequent resets which would lead to
  // irregular sampling.
  // TODO: Ideally there would be a targetTimestamp of display link used by the flutter engine.
  // https://github.com/flutter/flutter/issues/159087
  CFTimeInterval currentTime = CACurrentMediaTime();
  CFTimeInterval duration = self.frameUpdater.frameDuration;
  if (fabs(self.targetTime - currentTime) > duration * resetThreshold) {
    self.targetTime = currentTime;
  }
  self.targetTime += duration;

  CVPixelBufferRef buffer = NULL;
  CMTime outputItemTime = [self.videoOutput itemTimeForHostTime:self.targetTime];
  if ([self.videoOutput hasNewPixelBufferForItemTime:outputItemTime]) {
    buffer = [self.videoOutput copyPixelBufferForItemTime:outputItemTime itemTimeForDisplay:NULL];
    if (buffer) {
      // Balance the owned reference from copyPixelBufferForItemTime.
      CVBufferRelease(self.latestPixelBuffer);
      self.latestPixelBuffer = buffer;
    }
  }

  if (self.waitingForFrame && buffer) {
    self.waitingForFrame = NO;
    // If the display link was only running temporarily to pick up a new frame while the video was
    // paused, stop it again.
    if (!self.isPlaying) {
      self.displayLink.running = NO;
    }
  }

  // Calling textureFrameAvailable only from within displayLinkFired would require a non-trivial
  // solution to minimize missed video frames due to race between displayLinkFired, copyPixelBuffer
  // and place where is _textureFrameAvailable reset to false in the flutter engine.
  // TODO: Ideally FlutterTexture would support mode of operation where the copyPixelBuffer is
  // called always or some other alternative, instead of on demand by calling textureFrameAvailable.
  // https://github.com/flutter/flutter/issues/159162
  if (self.displayLink.running && self.selfRefresh) {
    // The number of frames over which to measure average frame duration.
    const int windowSize = 10;
    // If measured average frame duration is shorter than this fraction of frame duration obtained
    // from display link then rely solely on refreshes from display link.
    const float durationThreshold = 0.5;
    // If duration changes by this fraction or more then reset average frame duration measurement.
    const float resetFraction = 0.01;

    if (fabs(duration - self.latestDuration) >= self.latestDuration * resetFraction) {
      self.startTime = currentTime;
      self.framesCount = 0;
      self.latestDuration = duration;
    }
    if (self.framesCount == windowSize) {
      CFTimeInterval averageDuration = (currentTime - self.startTime) / windowSize;
      if (averageDuration < duration * durationThreshold) {
        NSLog(@"Warning: measured average duration between frames is unexpectedly short (%f/%f), "
              @"please report this to "
              @"https://github.com/flutter/flutter/issues.",
              averageDuration, duration);
        self.selfRefresh = false;
      }
      self.startTime = currentTime;
      self.framesCount = 0;
    }
    self.framesCount++;

    dispatch_async(dispatch_get_main_queue(), ^{
      [self.frameUpdater.registry textureFrameAvailable:self.frameUpdater.textureIdentifier];
    });
  }

  // Add a retain for the engine, since the copyPixelBufferForItemTime has already been accounted
  // for, and the engine expects an owning reference.
  return CVBufferRetain(self.latestPixelBuffer);
}

- (void)onTextureUnregistered:(NSObject<FlutterTexture> *)texture {
  dispatch_async(dispatch_get_main_queue(), ^{
    if (!self.disposed) {
      FlutterError *error;
      [self disposeWithError:&error];
    }
  });
}

#pragma mark - Picture in Picture

/// Sets up the picture in picture controller and assigns the AVPictureInPictureControllerDelegate
/// to the controller.
- (void)setUpPictureInPictureController {
  if (@available(macOS 10.15, iOS 9.0, *)) {
    if (AVPictureInPictureController.isPictureInPictureSupported) {
      self.pictureInPictureController =
          [[AVPictureInPictureController alloc] initWithPlayerLayer:self.playerLayer];
      [self setAutomaticallyStartPictureInPicture:NO];
      _pictureInPictureController.delegate = self;
    }
  }
}

- (void)setAutomaticallyStartPictureInPicture:(BOOL)enabled {
  if (!self.pictureInPictureController) return;
#if TARGET_OS_IOS
  if (@available(iOS 14.2, *)) {
    self.pictureInPictureController.canStartPictureInPictureAutomaticallyFromInline = enabled;
  }
#endif
}

- (void)setPictureInPictureOverlayFrame:(CGRect)frame {
  self.playerLayer.frame = frame;
}

- (void)setPictureInPictureStarted:(BOOL)startPictureInPicture {
  if (@available(macOS 10.15, iOS 9.0, *)) {
    if (!AVPictureInPictureController.isPictureInPictureSupported ||
        self.pictureInPictureStarted == startPictureInPicture) {
      return;
    }
  } else {
    return;
  }

  [super setPictureInPictureStarted:startPictureInPicture];

  if (self.pictureInPictureStarted && ![self.pictureInPictureController isPictureInPictureActive]) {
    if (self.eventListener) {
      // The event is sent here to make sure that the Flutter UI can be updated as soon as possible.
      if (@available(macOS 10.15, iOS 9.0, *)) {
        [self.eventListener videoPlayerDidStartPictureInPicture];
      }
    }
    [self.pictureInPictureController startPictureInPicture];
  } else if (!self.pictureInPictureStarted &&
             [self.pictureInPictureController isPictureInPictureActive]) {
    [self.pictureInPictureController stopPictureInPicture];
  }
}

#pragma mark - AVPictureInPictureControllerDelegate

- (void)pictureInPictureControllerDidStopPictureInPicture:
    (AVPictureInPictureController *)pictureInPictureController API_AVAILABLE(macos(10.15), ios(9.0)) {
  self.pictureInPictureStarted = NO;
  if (self.eventListener) {
    [self.eventListener videoPlayerDidStopPictureInPicture];
  }
}

- (void)pictureInPictureControllerDidStartPictureInPicture:
    (AVPictureInPictureController *)pictureInPictureController API_AVAILABLE(macos(10.15), ios(9.0)) {
  self.pictureInPictureStarted = YES;
  if (self.eventListener) {
    [self.eventListener videoPlayerDidStartPictureInPicture];
  }
  [self updatePlayingState];
}

@end
