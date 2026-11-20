# Phase 0 feasibility

## Current evidence

| Gate | Status |
|---|---|
| Mac build and automated tests | Five tests passed on macOS 27.2.1 with Xcode 27.2. They cover URL parsing, loop bounds, seek and replay decisions, and reopening a disk-backed SwiftData store. |
| iPad build and automated tests | Compiles for iPadOS. The test suite passed on the iPadOS 17.5 simulator. The paired physical iPad was unavailable. |
| Embed identity, playback and interruption recovery | Pending hands-on verification. |
| Loop endpoints, audible gap, slowdown and pitch | Pending measurement. |
| Saved record after force-quit and offline | Pending manual verification. Disk round-trip is covered by automation. |
| Distribution | The proposed design uses the official embed. The acceptability of scripted loop seeks and bounded replay remains open. |

## Device checklist

1. Generate the fixture below and upload it to your own YouTube account with embedding allowed. Use the resulting URL on both devices. The video has a 440 Hz reference and a higher-frequency pulse at each whole second.
2. On each device, record OS, video ID, network conditions, and player layout. Start from the YouTube play button and verify inline playback. Try an unavailable or embed-disabled clip to check the error and **Open in YouTube** action. Record any identity error (`153`).
3. Compare **Jump to loop start** with **Reload loop segment** in the playback-options menu. Set A at 5 s and B at 7 s, then 13 s. With warm playback, run 20 repeats per combination at confirmed 0.5×, 0.75×, and 1×. Use the timecode and pulses to measure observed boundaries and the wall-clock gap from B to A. Aim for at least 19 of 20 wraps within ±250 ms at both endpoints and under 500 ms between B and A. Playback diagnostics use the system log under the RiffPractice Playback category. The command-to-sample interval is a proxy for the audible gap. Record cold seeks, buffering, and ads separately.
4. Measure the reference tone with an external tuner or analyzer. Target ±10 cents at 0.5× and 0.75× against the measured 1× baseline. Confirm media time advances at the selected rate and listen for artifacts on two guitar clips, including a fast riff. Record unsupported rates and any resets in rate during bounded replay.
5. Save a named section at 0.75×. Force-quit, disable networking, relaunch, and reopen the saved record. Verify link, name, range, and preferred rate. Restore networking, load the video, and verify actual speed after pressing Play. Try losing the network, backgrounding the app, or shrinking the window mid-loop. Verify the loop stops when the player becomes inactive and waits for user action on return.

Create a 30-second timecoded fixture with FFmpeg:

```sh
ffmpeg -f lavfi -i 'testsrc=size=960x540:rate=30:decimals=3:duration=30' \
  -f lavfi -i "aevalsrc='0.20*sin(2*PI*440*t)+0.16*sin(2*PI*880*t)*lt(mod(t,1),0.06)':d=30:s=48000" \
  -c:v libx264 -pix_fmt yuv420p -c:a aac -movflags +faststart riffpractice-fixture.mp4
```

## Release decision

- Keep the official player visible and unobscured with documented client identity, attribution, controls, and ads intact. The minimum viewport is 200 × 200 px. Investigate any ad interference before selecting a loop strategy. [YouTube embed requirements](https://developers.google.com/youtube/terms/required-minimum-functionality) · [YouTube developer policies](https://developers.google.com/youtube/terms/developer-policies)
- Prepare app terms and a privacy policy, document embed traffic and local storage, and provide a native practice walkthrough and sample clips for App Review. Check guidelines 4.2, 5.1, 5.2.2, and 5.2.3. [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/) · [App Privacy Details](https://developer.apple.com/app-store/app-privacy-details/)
- Choose a production loop strategy after both devices pass. If short loops miss, test a longer minimum loop or user-triggered jumps. If slowdown fails the pitch check, narrow supported rates and retest. Resolve open playback policy questions before public distribution.
