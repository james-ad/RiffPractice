# RiffPractice

Native SwiftUI guitar-practice prototype for iPad and Mac. Save named sections for each YouTube video and choose how to repeat them.

## Run

1. Open `RiffPractice.xcodeproj` in Xcode and select the **RiffPractice** scheme.
2. Select your development team in **Signing & Capabilities**, then select **My Mac** or your connected iPad and run. Both targets use the same CloudKit container and require iCloud and Push Notifications provisioning.
3. Paste a YouTube URL and choose **Load Video**, then press Play in the embed. Set A and B, give the section a name, and choose **Save Section**. Repeat for each song part. Use the bookmark menu to reopen videos with saved sections.
4. Use a section's repeat button to loop it alone, or check several and choose **Loop Selected**. Touching or overlapping sections play continuously as one range. Gaps between selected sections are skipped. The jump button takes you to the start of a section for play-through.
5. Choose **Loop Entire Video** to repeat the full performance, or **Stop Looping** to play through normally. Use a section's options menu to edit or delete it.

The practice timeline beneath the video shows saved section markers and the current playhead. Click or drag the timeline to seek on release, or click a marker to jump to its section. Seeking ends any active loop. The Sections list sits beside the video on wider windows and below it in compact layouts.

Use **Name Session** above the section list to save a title for the video. Open it again by name from **Saved Sessions** in the bookmark menu. Renaming a session keeps its saved sections and times intact.

## Adjust markers

Choose **Edit Section** from a section's options menu. Drag the A and B handles underneath the timeline to move the endpoints and preview the video position. Release to save the changed endpoints. The handles use separate rows so short sections remain adjustable. The text fields still support exact times in seconds. **New Section** creates a five-second draft at the current playhead with both handles ready to move. Name the draft and choose **Save Section** to keep it.

## iCloud

The library uses SwiftData with the private CloudKit container `iCloud.com.jamesdunn.riffpractice`. Sign in to the same Apple account on Mac and iPad and use builds connected to the same CloudKit environment. Session names, saved sections, endpoint changes, deletions, and preferred video speed sync automatically as the system schedules transfers. The cloud menu shows account and transfer status. Playback and the active loop selection remain local to each device.

On first launch of this version, the app exports a JSON backup of the previous library and imports its sections and session names into a separate library store. The original `default.store` and the old session-name preferences remain available. The import is retryable and tracks completed snapshots so deleted sections stay deleted. Use the cloud menu's **Export Original Marker Backup** to keep another copy.

These development builds use CloudKit's **Development** environment. Before TestFlight or App Store distribution, promote the schema in CloudKit Console and use production provisioning. Cross-device testing requires two signed builds, both signed in to the same Apple account. Verify renames and endpoint edits in both directions, a deletion, offline edits followed by reconnection, and a force-quit/relaunch. The first upload may take time.

For local automated testing, override `CODE_SIGN_ENTITLEMENTS=Config/Mac.entitlements` and `RIFFPRACTICE_CLOUD_SYNC=NO`. The unit-test host uses an in-memory library while persistence tests create their own disk stores.

Run `xcodegen generate` to regenerate the project after editing `project.yml`. Run Mac tests with `xcodebuild -project RiffPractice.xcodeproj -scheme RiffPractice -destination 'platform=macOS' test`.

See [the spike checklist](SPIKE.md) for physical-device testing and decision criteria.
