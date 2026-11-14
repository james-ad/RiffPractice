# RiffPractice

Native SwiftUI guitar-practice prototype for iPad and Mac. Save named sections for each YouTube video and choose how to repeat them.

## Run

1. Open `RiffPractice.xcodeproj` in Xcode and select the **RiffPractice** scheme.
2. Select **My Mac** and run. The Mac build uses ad-hoc signing with App Sandbox and outgoing network access. For a physical iPad, select your development team in **Signing & Capabilities**, then select the connected iPad.
3. Paste a YouTube URL and choose **Load Video**, then press Play in the embed. Set A and B, give the section a name, and choose **Save Section**. Repeat for each song part. Use the bookmark menu to reopen videos with saved sections.
4. Use a section's repeat button to loop it alone, or check several and choose **Loop Selected**. The app cycles through them in song order, skipping gaps. The jump button takes you to the start of a section for play-through.
5. Choose **Loop Entire Video** to repeat the full performance, or **Stop Looping** to play through normally. Use a section's options menu to edit or delete it.

Run `xcodegen generate` to regenerate the project after editing `project.yml`. Run Mac tests with `xcodebuild -project RiffPractice.xcodeproj -scheme RiffPractice -destination 'platform=macOS' test`.

See [the spike checklist](SPIKE.md) for physical-device testing and decision criteria.
