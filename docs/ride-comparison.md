# Ride comparison prototype

This branch adds an iPhone **Rides** tab and **Compare Ride Prices** App Intent to the upstream agent. It is a prototype, not a verified live integration with the three providers.

## Current trial: an ordinary saved intent

The first live trial uses the existing Agent and saved-intent flow. A saved task already stores a name, a plain prompt and optional hints. The custom Rides controller below remains experimental and is not required for this trial.

Replace both route placeholders before running this prompt, then save the successful run as an intent using the existing app controls:

> Compare rides from [exact pickup] to [exact destination] now. Open Uber, Lyft and Waymo in turn and use the same pickup and destination in each. Check UberX, standard Lyft and Waymo. Read the displayed fare, currency, pickup wait and trip duration. Report unavailable services and unreadable values rather than guessing. Include the route and any fare ranges or conditions shown, then identify the lowest observed comparable fare. Only inspect quotes: never request, book, reserve, confirm or pay for a ride. Stop if reaching a quote would require one of those actions.

This generic prompt does not enable the custom controller's OCR action guards or structured fare validation. Supervise the trial and verify the displayed route and quotes. Live comparison remains unvalidated.

### Working memory during a run

The generic iOS agent now keeps a bounded list of model-observed facts and subtask status (`observed`, `done`, or `pending`). The actor emits `MEMORY:` JSON lines in the same response as its next action; there is no separate summarization call. Notes retain observation timestamps and reach every subsequent actor and planner request, even after the eight-action history window rolls over, a gesture fails, or the connection recovers. Each key can be corrected without losing other results. The model is instructed to verify completion from the screen before marking a subtask done, then continue remaining work.

Memory updates are validated atomically (32 topics, 400 characters per value) and archived in `steps.jsonl` immediately after the model call containing their source screenshot. Invalid notes trigger a format retry before any gesture. Memory resets when starting or clearing a run; it is not restored after an app restart or copied into saved intents. Old fares therefore do not become fresh quotes on the next run. These notes remain model interpretations, not OCR-verified facts, and do not guarantee that the model will avoid every repeated action.

### Ordered execution and continuous video

The iOS planner now produces 1–12 checkpoints with explicit verification conditions and dependency groups. For ride comparisons it is instructed to plan opening each requested provider, entering/verifying the exact destination, and collecting its quote, followed by comparison. The harness supplies one active checkpoint at a time. The actor records screen evidence with `DO checkpoint ...` before advancing; `DO blocked ...` marks a source and its remaining dependent steps unavailable. It cannot finish early or batch gestures while checkpoints remain. A final answer can complete the last checkpoint. Recovery planning changes only the current strategy, never resets completed checkpoints. Each checkpoint gets a repair after six actions and asks for help after twelve; the entire run is bounded to 100 rounds. Home's **Plan and progress** shows outcomes/evidence. Verification is still model-based, not proof that a provider screen was interpreted correctly.

In stream mode the app now keeps forwarding/decoding video between runs, calibration and demonstrations. Previously, ending a task paused forwarding while AirPlay continued filling the Watcher's finite GOP buffer. The next task could no longer decode the truncated history. Healthy unchanged frames no longer trigger a snapshot, and command timeouts no longer silently switch to snapshot mode. Explicit snapshot mode remains available. Continuous mirroring uses BLE/decoder resources while idle, but run video recording stops at task end. An app reinstall/relaunch, a dropped video chunk, or transport overflow can still require a new keyframe or a mirroring restart; this change prevents the task-end pause rather than implementing AirPlay keyframe requests.

Live validation on October 16: two consecutive read-only status-bar tasks completed, followed by multiple navigation/quote tasks in the same AirPlay session without a restart. The ten-checkpoint comparison plan covered all requested providers. The initial Uber route verification still looped: the route editor named the selected station while the quote header used its street name. A focused quote-reading task succeeded after that route was independently checked. Planner/actor guidance now treats already-correct populated route fields as completion evidence rather than requiring repeated destination entry or an identical map label. This is evidence for video continuity and a specific navigation correction, not a completed autonomous three-provider comparison.

Focused Lyft launch and route/quote tasks also succeeded, and their final screenshot corroborated the fare, wait and discount. Waymo launch initially stalled while repeatedly tapping a focused Spotlight field to summon an onscreen keyboard; explicit hardware-keyboard guidance resolved that launch. The actor now receives detailed acceptance criteria only for its active checkpoint, clears recovery guidance on advancement, and is told that hardware typing does not require a visible onscreen keyboard. These refinements pass 114 simulator tests and a signed device build; the complete revised comparison still requires live validation.

### Follow-up: learn a workflow, then reuse it

Saved intents currently retain prompts and hints, not executable scripts. The intended next step is to derive a workflow from a successful supervised run, with pickup/destination as parameters and screen checks between actions. Use local text/visual matching for familiar screens, and ask the model to recover when a checkpoint fails. Avoid blind coordinate playback. Fares, availability and pickup estimates still require a fresh observation each run. Model planning, gesture execution and screen settling are separate latency costs; fewer model calls alone will not remove the latter two.

## Run it

1. In `ios/Config/Local.xcconfig`, set your development team and a unique bundle identifier, following the example file. Keep model credentials in the app's Settings/Keychain.
2. Open `ios/IPhoneAgent.xcodeproj`, select your iPhone, and build/run. Complete the upstream board, AirPlay, AssistiveTouch/pointer calibration, and model setup.
3. Open **Rides**. Enter a specific pickup and destination including city and entrance. Use the iPhone keyboard microphone for dictation, then check both addresses.
4. Tap **Compare rides**. Keep the phone unlocked and supervise. Use **Stop comparison** or the existing Live Activity stop control at any time.
5. The controller checks Uber, Lyft, and Waymo sequentially. Review the screenshot attached to each result. **Export comparison JSON** shares the structured report.

For Shortcuts: add **Dictate Text**, then **Compare Ride Prices** from ESP32 Agent. Supply a fixed pickup address and use Dictated Text as Destination address. This uses system dictation; offline availability depends on iPhone language/device settings. Watcher microphone capture is not implemented yet.

The iPhone still needs cellular internet for ride apps and the configured model. The bridge creates a local Wi-Fi network for AirPlay and does not need internet or the iPhone Personal Hotspot.

## What is implemented

- One immutable trip and separate bounded agent runs for each provider.
- Standard private ride options: UberX, standard Lyft, Waymo.
- Screenshot evidence from the exact observation that produced the agent's `done` action, with its observation timestamp.
- Apple Vision OCR on the phone, retaining text and screen coordinates.
- A separate model extraction pass using the screenshot and OCR. Unknown/mismatched routes, providers, currency, ambiguous fares, ranges, and absent OCR corroboration are rejected.
- Initial fare support is deliberately limited to a single USD amount with two decimal places. The literal fare must match a complete OCR observation. Combined OCR rows or unsupported layouts will be unreadable rather than guessed. An unqualified `$` alone does not establish USD; the extractor must establish the currency from the screen.
- Failure isolation: unavailable providers do not discard other results; cancellation stops the remaining providers.
- Saved reports, source screenshots, OCR, and extraction replies under `Documents/ride-comparisons/<UUID>/`. The latest report reloads after relaunch. An interrupted report never resumes automation by itself.
- A lowest-observed label using only eligible quotes under five minutes old. It can represent partial results; it is not a guaranteed market-wide cheapest fare.

## Control limits

The task explicitly prohibits booking. Comparison runs use one model action per observation, check the current frame for changes before acting, reject keyboard shortcuts/control characters and drawing gestures, and block taps near OCR labels such as Request, Book, Reserve, Confirm, and Pay. These checks are **best effort**, not a formal no-booking guarantee: OCR can miss text and app layouts can change. Live runs require supervision. No automatic booking feature is included.

Full screenshots still go to the navigation model and final extraction pass. OCR currently provides local evidence and action checks; text-only navigation/vision fallback is a later optimization. The model's route/ride-type interpretation is not ground truth; review the saved evidence. Both route endpoints must be visible on the final screen or the quote is rejected, even if the agent set them earlier.

Ride results are stored separately from upstream run archives. The upstream trace export/deletion UI does not currently manage these folders. Delete or copy them through Finder's app file sharing; uninstalling the app removes its local data. Screenshots may contain personal trip information.

## Validation

Run the upstream iOS suite, including `RideComparisonTests`:

```sh
cd ios
xcodegen
xcodebuild test -scheme IPhoneAgent \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath build-sim CODE_SIGNING_ALLOWED=NO
```

Tests cover route/currency/OCR rejection, invalid trip input, stale-result ranking, provider failures, persisted reports, cancellation, action blocking, and action-guard ordering. They do not prove live fares, hardware control, or provider UI compatibility.

## Remaining milestones

1. Validate Watcher Bluetooth HID pairing, keyboard/mouse input and reconnect behavior (see `watcher-bringup.md`), then validate simultaneous AirPlay/video/HID.
2. Run supervised provider trials using a configured model and the user's signed-in apps; capture screen fixtures for extraction tests.
3. Extend the initial Watcher power port with display, button and audio drivers.
4. Add a versioned BLE audio/result protocol and Watcher microphone capture/display.
5. Reduce remote image traffic using OCR-led navigation with visual fallback.
