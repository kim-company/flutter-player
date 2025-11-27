// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.videoplayer.texture;

import androidx.annotation.NonNull;
import androidx.annotation.OptIn;
import androidx.media3.common.Format;
import androidx.media3.common.VideoSize;
import androidx.media3.exoplayer.ExoPlayer;
import io.flutter.plugins.videoplayer.ExoPlayerEventListener;
import io.flutter.plugins.videoplayer.VideoPlayerCallbacks;
import java.util.Objects;

public final class TextureExoPlayerEventListener extends ExoPlayerEventListener {
  private final boolean surfaceProducerHandlesCropAndRotation;

  // HLS buffer duration to exclude from reported duration (matches iOS behavior)
  private static final long HLS_BUFFER_MS = 18000; // 18 seconds

  public TextureExoPlayerEventListener(
      @NonNull ExoPlayer exoPlayer,
      @NonNull VideoPlayerCallbacks events,
      boolean surfaceProducerHandlesCropAndRotation) {
    super(exoPlayer, events);
    this.surfaceProducerHandlesCropAndRotation = surfaceProducerHandlesCropAndRotation;
  }

  @Override
  protected void sendInitialized() {
    VideoSize videoSize = exoPlayer.getVideoSize();
    RotationDegrees rotationCorrection = RotationDegrees.ROTATE_0;
    int width = videoSize.width;
    int height = videoSize.height;
    if (width != 0 && height != 0) {
      // When the SurfaceTexture backend for Impeller is used, the preview should already
      // be correctly rotated.
      if (!surfaceProducerHandlesCropAndRotation) {
        // The video's Format also provides a rotation correction that may be used to
        // correct the rotation, so we try to use that to correct the video rotation
        // when the ImageReader backend for Impeller is used.
        int rawVideoFormatRotation = getRotationCorrectionFromFormat(exoPlayer);

        try {
          rotationCorrection = RotationDegrees.fromDegrees(rawVideoFormatRotation);
        } catch (IllegalArgumentException e) {
          // Rotation correction other than 0, 90, 180, 270 reported by Format. Because this is
          // unexpected we apply no rotation correction.
          rotationCorrection = RotationDegrees.ROTATE_0;
        }
      }
    }
    boolean isLive = exoPlayer.isCurrentMediaItemDynamic();
    events.onInitialized(width, height, getDuration(), rotationCorrection.getDegrees(), isLive);
  }

  @OptIn(markerClass = androidx.media3.common.util.UnstableApi.class)
  // A video's Format and its rotation degrees are unstable because they are not guaranteed
  // the same implementation across API versions. It is possible that this logic may need
  // revisiting should the implementation change across versions of the Exoplayer API.
  private int getRotationCorrectionFromFormat(ExoPlayer exoPlayer) {
    Format videoFormat = Objects.requireNonNull(exoPlayer.getVideoFormat());
    return videoFormat.rotationDegrees;
  }

  /**
   * Gets the duration of the video, excluding HLS buffer.
   * For HLS livestreams, subtracts the buffer duration from the total duration.
   * This matches the iOS implementation behavior.
   */
  private long getDuration() {
    // For HLS livestreams, the total duration includes the buffer.
    // Subtract the HLS buffer to get the actual seekable duration.
    if (exoPlayer.isCurrentMediaItemDynamic()) {
      long totalDuration = exoPlayer.getDuration();
      if (totalDuration != androidx.media3.common.C.TIME_UNSET) {
        return Math.max(0, totalDuration - HLS_BUFFER_MS);
      }
    }

    // For non-live content, use the standard duration
    return exoPlayer.getDuration();
  }
}
