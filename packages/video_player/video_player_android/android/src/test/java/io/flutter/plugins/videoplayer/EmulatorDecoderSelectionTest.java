// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.videoplayer;

import static org.junit.Assert.assertEquals;

import androidx.media3.common.MimeTypes;
import androidx.media3.exoplayer.mediacodec.MediaCodecInfo;
import androidx.media3.exoplayer.mediacodec.MediaCodecSelector;
import androidx.media3.exoplayer.mediacodec.MediaCodecUtil;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;

/** Unit tests for {@link VideoPlayer#withoutEmulatorDecoders(MediaCodecSelector)}. */
@RunWith(RobolectricTestRunner.class)
public final class EmulatorDecoderSelectionTest {
  private static MediaCodecInfo decoder(String name) {
    return MediaCodecInfo.newInstance(
        name, MimeTypes.VIDEO_H264, MimeTypes.VIDEO_H264, null, false, false, false, false, false);
  }

  private static List<String> names(List<MediaCodecInfo> decoders) {
    List<String> names = new ArrayList<>();
    for (MediaCodecInfo decoder : decoders) {
      names.add(decoder.name);
    }
    return names;
  }

  private static List<String> select(MediaCodecInfo... decoders)
      throws MediaCodecUtil.DecoderQueryException {
    MediaCodecSelector selector = (mimeType, secure, tunneling) -> Arrays.asList(decoders);
    return names(
        VideoPlayer.withoutEmulatorDecoders(selector)
            .getDecoderInfos(MimeTypes.VIDEO_H264, false, false));
  }

  @Test
  public void skipsGoldfishDecodersWhenOthersAreAvailable()
      throws MediaCodecUtil.DecoderQueryException {
    assertEquals(
        Arrays.asList("c2.android.avc.decoder"),
        select(decoder("c2.goldfish.h264.decoder"), decoder("c2.android.avc.decoder")));
  }

  @Test
  public void keepsGoldfishDecoderWhenItIsTheOnlyOne() throws MediaCodecUtil.DecoderQueryException {
    assertEquals(
        Arrays.asList("c2.goldfish.h264.decoder"), select(decoder("c2.goldfish.h264.decoder")));
  }

  @Test
  public void leavesDeviceDecodersUntouched() throws MediaCodecUtil.DecoderQueryException {
    assertEquals(
        Arrays.asList("c2.mtk.avc.decoder", "c2.android.avc.decoder"),
        select(decoder("c2.mtk.avc.decoder"), decoder("c2.android.avc.decoder")));
  }
}
