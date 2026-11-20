# RiffPractice

Native SwiftUI guitar-practice prototype for iPad and Mac. Save named sections for each YouTube video and choose how to repeat them.

## Run

1. Open `RiffPractice.xcodeproj` in Xcode and select the **RiffPractice** scheme.
2. Select your development team in **Signing & Capabilities**, then select **My Mac** or your connected iPad and run. Both targets use the same CloudKit container and require iCloud and Push Notifications provisioning.
3. Choose **New Session**, enter a name and a YouTube link, and choose **Use YouTube Video**. Press Play in the video, set A and B, name the section, and choose **Save Section**. Repeat for each song part. **Open Session** lists saved sessions by name. A link that is already saved reopens its existing session.
4. Use a section's repeat button to loop it alone, or check several and choose **Loop Selected**. Touching or overlapping sections play continuously as one range. Gaps between selected sections are skipped. The jump button takes you to the start of a section for play-through.
5. Choose **Loop Entire Video** to repeat the full performance, or **Stop** in the active-loop strip to play through normally. Use a section's options menu to edit or delete it.

The practice timeline beneath the video shows saved section markers and the current playhead. Click or drag the track to seek on release. Choose a marker to jump to and edit that section. Nearby markers use staggered rows or a chooser so every section stays reachable. Seeking ends any active loop.

Use **Name Session** or **Rename Session** above the section list to change its title. Renaming a session keeps its saved sections and times intact.

## Workspace

**Hide Sections** expands the video workspace while a compact strip below the timeline shows the sections currently repeating. **Show Sections** restores the editing list. Use the layout menu to place the list on the left, right, or below the video. Narrow windows use the below-video layout. Drag the side-panel divider to adjust its width between 280 and 320 points. Layout choices are saved on each device.

The playback-options menu beside Speed contains the repeat method. **Jump to loop start** returns to the start when a loop ends. **Reload loop segment** is the alternate playback method. The same menu lets you enable or skip the new-session confirmation. Starting a new session clears unsaved edits. Saved sessions remain available in **Open Session**.

## Adjust markers

The compact timeline places all A/start flags above the track and all B/end flags below it. Each shield-shaped flag has a stem to its exact time. Choose a flag or **Edit Section** to adjust that section. Drag its highlighted A or B flag and release to save. The visible flags are compact, with larger invisible touch targets. Crowded endpoints offer a section chooser within their own A or B row.

The text fields support exact times in seconds. **New Section** creates a five-second draft at the current playhead with both endpoints ready to move. Name the draft and choose **Save Section** to keep it.

## Video size and full-screen practice

The editor starts with a 16:9 player. Drag the grip immediately beneath the video to adjust its height, or choose **Reset Video Size** in the layout menu. The video, timeline, and controls scroll together, keeping the controls reachable in smaller windows. Scrolling most of the video out of view pauses playback.

Use the expand icon beside the app title to enter full-screen practice. The same YouTube player and loop continue in a black, fitted workspace. The control strip below the video contains play/pause, speed, stop-loop, and exit controls. It fades after three seconds of inactivity while playing and returns with pointer movement or a tap. Controls stay visible while paused, when hovered, or with VoiceOver enabled. Use the exit icon or Escape to return to editing. Pausing keeps the active loop ready to resume.

## iCloud

The library uses SwiftData with the private CloudKit container `iCloud.com.jamesdunn.riffpractice`. Sign in to the same Apple account on Mac and iPad and use builds connected to the same CloudKit environment. Session names, saved sections, endpoint changes, deletions, and preferred video speed sync automatically as the system schedules transfers. The cloud menu shows account and transfer status. Playback and the active loop selection remain local to each device.

On first launch of this version, the app exports a JSON backup of the previous library and imports its sections and session names into a separate library store. The original `default.store` and the old session-name preferences remain available. The import is retryable and tracks completed snapshots so deleted sections stay deleted. Use the cloud menu's **Export Original Marker Backup** to keep another copy.

These development builds use CloudKit's **Development** environment. Before TestFlight or App Store distribution, promote the schema in CloudKit Console and use production provisioning. Cross-device testing requires two signed builds, both signed in to the same Apple account. Verify renames and endpoint edits in both directions, a deletion, offline edits followed by reconnection, and a force-quit/relaunch. The first upload may take time.

For local automated testing, override `CODE_SIGN_ENTITLEMENTS=Config/Mac.entitlements` and `RIFFPRACTICE_CLOUD_SYNC=NO`. The unit-test host uses an in-memory library while persistence tests create their own disk stores.

Run `xcodegen generate` to regenerate the project after editing `project.yml`. Run Mac tests with `xcodebuild -project RiffPractice.xcodeproj -scheme RiffPractice -destination 'platform=macOS' test`.

See [the spike checklist](SPIKE.md) for physical-device testing and decision criteria.
