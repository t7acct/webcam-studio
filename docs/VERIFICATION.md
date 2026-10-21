# Verification

Tested on 21 October 2026 with an M1 Pro MacBook Pro, macOS 27.0.1, Swift 6.4 and macOS SDK 27.0. Capture used a UGREEN USB camera and its microphone. The app targets macOS 15 on Apple silicon.

## Builds and automated checks

Both `./build.sh` and the Xcode Release scheme build successfully. The local app passes strict code-signature verification.

`./test.sh` passes 29 checks covering:

- Automatic exposure bounds, smoothing and highlight protection.
- Exact device frame-duration negotiation.
- Neutral settings and enhancement bypass.
- Shadow preservation, warmth direction and original/enhanced preview routing.
- Background bypass, person-mask composition and isolated-object cleanup.
- Missing-mask/photo fallback and background image sizing.
- Overwrite refusal, MP4 finalisation, resolution, timestamps and decoded colour.
- Background replacement in the encoded MP4.

`./inspect.sh` fully decodes H.264 and AAC streams and checks monotonic video timestamps and an unmirrored identity transform. It also reports audio levels and frame gaps.

## Camera recordings

| Test | Duration | Decoded frames | Average FPS | Largest frame gap |
| --- | ---: | ---: | ---: | ---: |
| 720p, enhancement, no background effect | 180.033s | 5,385 | 29.91 | 0.267s |
| 1080p, enhancement, no background effect | 12.033s | 351 | 29.17 | 0.300s |
| 1080p, second take in the same session | 6.033s | 180 | 29.83 | 0.067s |
| 720p with background blur | 20.033s | 583 | 29.10 | 0.300s |
| 720p with blur, second take | 6.033s | 180 | 29.83 | 0.067s |

All clips contain H.264 video, non-silent AAC microphone audio and SDR BT.709 metadata. Complete decoding succeeded. The three-minute clip opened and played in QuickTime with the expected orientation and aspect ratio. Stop/start and normal quit both finalised the output and released capture devices.

The three-minute run reported no late-capture, pixel-pool or writer backpressure drops. Mean processing time was 3.49 ms/frame. Sampled process RSS peaked at 239.5 MiB and fell to about 100 MiB; no continuously growing process memory was observed. This measurement predates background effects and does not separately account for all GPU/driver memory.

With background blur enabled, mean frame processing was 5.95 ms and mean mask work was 31.54 ms on the separate segmentation queue. No capture, pool or writer backpressure drops were reported. These counters do not count gaps originating in the camera/source. The isolated gaps above mean the footage should not be described as perfectly smooth.

Blur, solid-colour and photo effects were also inspected on a recorded person frame. Cleanup removed disconnected room objects and faint background traces while retaining the presenter. A synthetic encode/decode check confirms that the composited background reaches the saved video.

## Manual checks still needed

- Listen to speech and compare lip movement/claps near the start and end. Matching track timelines do not establish physical lip sync.
- Check mask edges during fast movement, around loose hair, and when holding objects. The effect keeps the main presenter rather than every disconnected foreground object.
- Exercise physical disconnect/reconnect, denied permissions, competing camera use and actual disk exhaustion. Error handling exists for these paths, but these conditions were not deliberately induced.
- Complete keyboard and VoiceOver checks on the final controls.

Low light and source camera stalls remain practical limits. The initial MacBook microphone selection produced silence; the UGREEN microphone supplied sound. Check the meter before recording. Normal quit waits for finalisation; a forced kill or power loss can leave an incomplete hidden partial file.

Local clips, screenshots, raw diagnostics and one-off visual checks remain under `build/` and are excluded from the repository.
