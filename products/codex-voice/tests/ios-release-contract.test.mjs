import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import { test } from "node:test";

const read = (path) =>
  readFileSync(new URL(`../${path}`, import.meta.url), "utf8");

test("the iPhone companion is an Expo app with fingerprinted updates", () => {
  const app = JSON.parse(read("app.json"));
  const eas = JSON.parse(read("eas.json"));
  const rootPackage = JSON.parse(read("package.json"));

  assert.equal(rootPackage.main, "index.js");
  assert.equal(app.expo.version, "0.3.11");
  assert.ok(rootPackage.dependencies.expo);
  assert.ok(rootPackage.dependencies["expo-camera"]);
  assert.ok(rootPackage.dependencies["expo-updates"]);
  assert.ok(rootPackage.dependencies.react);
  assert.ok(rootPackage.dependencies["react-native"]);
  assert.equal(app.expo.runtimeVersion.policy, "fingerprint");
  assert.equal(
    app.expo.updates.url,
    "https://u.expo.dev/6fc127b3-71fb-4809-ada2-e4d8ffca36f4",
  );
  assert.equal(eas.build.production.channel, "production");
  assert.equal(eas.cli.appVersionSource, "remote");
  assert.equal(eas.build.production.autoIncrement, true);
  assert.equal(
    rootPackage.expo.doctor.appConfigFieldsNotSyncedCheck.enabled,
    false,
  );
});

test("iPhone Sentry is privacy-safe and has a controlled live verifier", () => {
  const telemetry = read("phoneTelemetry.js");
  const companion = read("App.js");

  assert.match(telemetry, /dataCollection: privateDataCollection/);
  assert.match(telemetry, /userInfo: false/);
  assert.match(telemetry, /cookies: false/);
  assert.match(telemetry, /httpHeaders: \{ request: false, response: false \}/);
  assert.match(telemetry, /httpBodies: \[\]/);
  assert.match(telemetry, /urlQueryParams: false/);
  assert.match(telemetry, /stackFrameVariables: false/);
  assert.match(telemetry, /attachScreenshot: false/);
  assert.match(telemetry, /attachViewHierarchy: false/);
  assert.match(telemetry, /enableLogs: true/);
  assert.match(telemetry, /logsOrigin: 'all'/);
  assert.match(telemetry, /_INTERNAL_captureLog/);
  assert.match(telemetry, /_INTERNAL_captureSerializedLog/);
  assert.match(telemetry, /Sentry\.getCurrentScope\(\)/);
  assert.match(telemetry, /timestamp: Date\.now\(\) \/ 1_000/);
  assert.match(telemetry, /noGeolocationUser = \{ ip_address: '0\.0\.0\.0' \}/);
  assert.match(telemetry, /tracesSampleRate: 1\.0/);
  assert.match(telemetry, /Sentry\.setUser\(noGeolocationUser\)/);
  assert.match(telemetry, /delete event\.tags\['app\.device'\]/);
  assert.match(telemetry, /delete event\.contexts\.culture/);
  assert.match(telemetry, /delete event\.contexts\.app\.device_app_hash/);
  assert.match(telemetry, /delete event\.request/);
  assert.match(telemetry, /Settings\.get\('CodexVoiceSentryVerification'\)/);
  assert.match(telemetry, /iphone\.telemetry\.verification/);
  assert.match(telemetry, /iPhone telemetry verification log/);
  assert.match(telemetry, /Controlled iPhone Sentry verification event/);
  assert.match(telemetry, /startTime: Date\.now\(\)/);
  assert.match(telemetry, /span\.end\(Date\.now\(\)\)/);
  assert.match(telemetry, /Sentry\.flush\(5_000\)/);
  assert.match(companion, /export default Sentry\.wrap\(App\)/);
  assert.doesNotMatch(telemetry, /transcript|audio_data|audio_bytes|pcm_bytes|pairing_secret/i);
});

test("Expo is connected to the checked-in iPhone and native Watch targets", () => {
  const appDelegate = read(
    "ios/CodexVoice/AppDelegate.swift",
  );
  const project = read("ios/CodexVoice.xcodeproj/project.pbxproj");
  const podfile = read("ios/Podfile");
  const expoPlist = read(
    "ios/CodexVoice/Supporting/Expo.plist",
  );
  const buildRecipe = read(".eas/build/production-ios.yml");
  const infoPlist = read("ios/CodexVoice/Info.plist");

  assert.match(appDelegate, /final class AppDelegate: ExpoAppDelegate/);
  assert.match(appDelegate, /ExpoAppDelegate/);
  assert.match(appDelegate, /ExpoReactNativeFactory/);
  assert.match(project, /Bundle React Native code and images/);
  assert.match(project, /CodexVoiceNative\.swift in Sources/);
  assert.match(project, /Expo\.plist in Resources/);
  assert.match(podfile, /use_expo_modules!/);
  assert.match(podfile, /use_react_native!/);
  assert.match(expoPlist, /file:fingerprint/);
  assert.match(expoPlist, /EXUpdatesEnableBsdiffPatchSupport/);
  assert.doesNotMatch(expoPlist, /expo-channel-name/);
  assert.match(buildRecipe, /command: pod install/);
  assert.match(buildRecipe, /eas\/configure_eas_update/);
  assert.match(infoPlist, /<string>codexvoice<\/string>/);
  assert.match(infoPlist, /<string>UIInterfaceOrientationPortrait<\/string>/);
  assert.match(
    infoPlist,
    /Pedro Voice Agent scans the one-time pairing QR shown by your Mac\./,
  );
  assert.match(infoPlist, /<key>ITSAppUsesNonExemptEncryption<\/key>\s*<false\/>/);
  assert.match(project, /PRODUCT_BUNDLE_IDENTIFIER = com\.pedro\.CodexVoice\.watchkitapp;/);
  assert.equal(
    (project.match(/MARKETING_VERSION = 0\.3\.11;/g) ?? []).length,
    2,
    "the iPhone and Watch targets must ship the same marketing version",
  );
  assert.match(project, /TARGETED_DEVICE_FAMILY = 1;/);
});

test("CI publishes OTA while the operator separately owns native builds", () => {
  const sourceWorkflow = read("../../.github/workflows/codex-voice-ci.yml");
  const updateScript = read("scripts/publish-ios-update.sh");
  const localBuildScript = read("scripts/build-ios-local.sh");
  const localBuildWorkflow = read(".eas/build/production-ios.yml");
  const mobilePackage = JSON.parse(read("package.json"));
  const easIgnore = read(".easignore");
  const fingerprintConfig = read("fingerprint.config.cjs");

  assert.match(sourceWorkflow, /runs-on: ubuntu-latest/);
  assert.doesNotMatch(sourceWorkflow, /runs-on: \[self-hosted/);
  assert.match(sourceWorkflow, /EXPO_TOKEN/);
  assert.match(sourceWorkflow, /^\s{2}push:/m);
  assert.match(sourceWorkflow, /npm run eas:update/);
  assert.doesNotMatch(sourceWorkflow, /\beas (?:build|submit|upload)\b/);
  assert.match(sourceWorkflow, /working-directory: products\/codex-voice/);
  assert.match(sourceWorkflow, /cancel-in-progress: false/);

  assert.match(updateScript, /node --test tests\/\*\.test\.mjs/);
  assert.match(updateScript, /npm run export:ios/);
  assert.match(
    updateScript,
    /expo-updates configuration:syncnative --platform ios --workflow generic/,
  );
  assert.match(updateScript, /update \\/);
  assert.match(updateScript, /--channel production/);
  assert.match(updateScript, /--platform ios/);
  assert.match(updateScript, /--environment production/);
  assert.doesNotMatch(updateScript, /fingerprint:generate|build:list/);
  assert.doesNotMatch(updateScript, /\beas\[@\].*(?:build|submit|upload)/);

  assert.match(
    localBuildScript,
    /fingerprint:generate --platform ios --build-profile production --json --non-interactive/,
  );
  assert.match(localBuildScript, /build:list[^\n]+--fingerprint-hash/);
  assert.match(
    localBuildWorkflow,
    /eas\/calculate_eas_update_runtime_version:\n\s+id: calculate_eas_update_runtime_version/,
  );
  assert.equal(
    localBuildWorkflow.match(
      /resolved_eas_update_runtime_version: \$\{ steps\.calculate_eas_update_runtime_version\.resolved_eas_update_runtime_version \}/g,
    )?.length,
    2,
    "Expo configuration and Fastlane must receive the calculated fingerprint",
  );
  assert.doesNotMatch(
    localBuildScript,
    /update --channel production|npm run eas:update/,
  );
  assert.match(
    localBuildScript,
    /A local native build is required\. Run npm run eas:build:local/,
  );
  assert.equal(
    localBuildScript.match(
      /build --platform ios --profile production --local --output/g,
    )?.length,
    1,
    "there must be exactly one local native build command",
  );
  assert.match(localBuildScript, /export TMPDIR="\$tmp_root\/"/);
  assert.match(localBuildScript, /export GYM_BUILD_PATH="\$archive_root"/);
  assert.match(
    localBuildScript,
    /export GYM_RESULT_BUNDLE_PATH="\$result_bundle_path"/,
  );
  assert.ok(
    localBuildScript.indexOf('export GYM_BUILD_PATH="$archive_root"') <
      localBuildScript.indexOf('"${eas[@]}" build --platform ios'),
    "Fastlane archive output must be clone-local before the build starts",
  );
  assert.match(
    localBuildScript,
    /submit --platform ios --profile production --path "\$artifact_path" --non-interactive --wait/,
  );
  assert.match(
    localBuildScript,
    /upload --platform ios --build-path "\$artifact_path" --fingerprint/,
  );
  assert.ok(
    localBuildScript.indexOf('"${eas[@]}" submit --platform ios') <
      localBuildScript.indexOf('"${eas[@]}" upload --platform ios'),
    "TestFlight submission must succeed before Expo records compatibility",
  );
  assert.doesNotMatch(
    localBuildScript,
    /workflow:run|type: build|build:cancel|submit:cancel/,
  );
  for (const buildListLine of localBuildScript.match(/^.*build:list.*$/gm) ?? []) {
    assert.doesNotMatch(
      buildListLine,
      /--build-profile|--distribution|--channel/,
      "uploaded local builds do not carry cloud-build profile metadata",
    );
  }
  assert.equal(
    existsSync(new URL("../.eas/workflows/testflight.yml", import.meta.url)),
    false,
    "the paid EAS cloud-build workflow must stay removed",
  );
  assert.equal(
    existsSync(
      new URL(
        "../../../.github/workflows/codex-voice-testflight.yml",
        import.meta.url,
      ),
    ),
    false,
    "there must be no separate native-release workflow",
  );
  assert.match(mobilePackage.scripts["eas:update"], /publish-ios-update\.sh/);
  assert.match(mobilePackage.scripts["eas:release"], /eas:update/);
  assert.match(mobilePackage.scripts["eas:plan"], /eas:native:check/);
  assert.match(
    mobilePackage.scripts["eas:native:check"],
    /build-ios-local\.sh --check/,
  );
  assert.match(mobilePackage.scripts["eas:build:local"], /build-ios-local\.sh/);
  assert.match(easIgnore, /^\.eas-local-build$/m);
  assert.match(fingerprintConfig, /PackageJsonScriptsAll/);
  assert.match(fingerprintConfig, /scripts\/publish-ios-update\.sh/);
  assert.match(fingerprintConfig, /scripts\/build-ios-local\.sh/);
  assert.match(fingerprintConfig, /ios\/\*\.xcworkspace\/\*\*/);
  assert.match(fingerprintConfig, /ios\/Pods\/\*\*/);
  assert.match(
    fingerprintConfig,
    /Bridge\/Sources\/CodexVoiceProtocol/,
  );
});

test("Watch pairing is acknowledged and can be resent without a new QR", () => {
  const protocol = read("Bridge/Sources/CodexVoiceProtocol/SecureBridgeProtocol.swift");
  const phone = read("ios/App/CodexVoicePhone/PhonePairingTransfer.swift");
  const nativeSwift = read("ios/App/CodexVoicePhone/CodexVoiceNative.swift");
  const nativeObjC = read("ios/App/CodexVoicePhone/CodexVoiceNative.m");
  const companion = read("App.js");
  const watch = read("ios/App/CodexVoiceWatch/WatchPairingReceiver.swift");
  const watchUI = read("ios/App/CodexVoiceWatch/ContentView.swift");

  assert.match(protocol, /watchPairingTransferIDContextKey/);
  assert.match(protocol, /watchPairingAcknowledgementContextKey/);
  assert.match(phone, /func resend\(\)/);
  assert.match(phone, /sessionWatchStateDidChange/);
  assert.match(phone, /report\(\.synced\)/);
  assert.match(nativeSwift, /"watchSyncPhase": watchSyncPhaseName/);
  assert.match(nativeSwift, /"watchReady": model\.watchSyncState\.isSynced/);
  assert.match(nativeSwift, /func resendToWatch/);
  assert.match(nativeObjC, /RCT_EXTERN_METHOD\(resendToWatch:/);
  assert.match(companion, /const watchReady = paired && state\.watchReady/);
  assert.match(companion, /Send to Apple Watch/);
  assert.match(companion, /Send again/);
  assert.match(watch, /func acknowledge\(transferID:/);
  assert.doesNotMatch(watchUI, /scan/i);
});

test("Watch rebuilds one duplex graph after media reset and reports startup precisely", () => {
  const watchApp = read("ios/App/CodexVoiceWatch/CodexVoiceWatchApp.swift");
  const watchModel = read("ios/App/CodexVoiceWatch/VoiceSessionModel.swift");
  const capture = read("ios/App/CodexVoiceWatch/WatchAudioCapture.swift");
  const player = read("ios/App/CodexVoiceWatch/RealtimeAudioPlayer.swift");
  const watchInfo = read("ios/App/CodexVoiceWatch/Info.plist");
  const phoneInfo = read("ios/CodexVoice/Info.plist");

  assert.match(watchModel, /setCategory\(\s*\.playAndRecord,/);
  assert.match(watchModel, /let sessionMode: AVAudioSession\.Mode = \.voiceChat/);
  assert.doesNotMatch(watchModel, /setCategory\(\s*\.record/);
  assert.match(watchModel, /session\.activate\(options:/);
  assert.match(watchApp, /let model = VoiceSessionModel\(\)/);
  assert.match(watchModel, /if Self\.debugAudioProbe \{\s*hasStarted = true\s*startDebugAudioProbe\(\)/);
  assert.match(watchModel, /WatchDuplexAudioEngine\(\)/);
  assert.match(watchModel, /WatchAudioCapture\(audioEngine: duplexAudioEngine\)/);
  assert.match(watchModel, /RealtimeAudioPlayer\(audioEngine: duplexAudioEngine\)/);
  assert.ok(
    watchModel.indexOf("session.activate(options: [])") <
      watchModel.indexOf("self.duplexAudioEngine.rebuildFreshGraph()") &&
      watchModel.indexOf("self.duplexAudioEngine.rebuildFreshGraph()") <
      watchModel.indexOf("self.duplexAudioEngine.configureForActiveSession"),
    "the Watch must activate its audio session before recreating and configuring the route-dependent graph",
  );
  assert.match(watchModel, /code: "audio_graph_configured"/);
  assert.match(watchModel, /code: "audio_graph_failed"/);
  assert.match(watchModel, /func debugPlaybackPCM\(\) -> \(data: Data, source: String\)/);
  assert.match(watchModel, /-CodexVoiceAudioProbePCM/);
  assert.match(watchModel, /return \(fixture, "backend_fixture"\)/);
  assert.match(watchModel, /let framePattern = \[113, 997, 2_048, 509\]/);
  assert.match(
    watchModel,
    /playbackChunks\.forEach \{ _ = self\.audioPlayer\.enqueue\(\$0\) \}/,
  );
  assert.match(watchModel, /code: "audio_probe_output_started"/);
  assert.match(watchModel, /audioPlayer\.finishStream\(\)/);
  assert.doesNotMatch(watchModel, /audioPlayer\.prime\(\)/);
  assert.match(watchModel, /startPendingBridgeConnection/);
  assert.match(watchModel, /code: "audio_session_activated"/);
  assert.match(watchModel, /code: "audio_session_failed"/);
  assert.match(watchModel, /stage: "activate_timeout"/);
  assert.match(watchModel, /Task\.sleep\(nanoseconds: 8_000_000_000\)/);
  assert.match(watchModel, /audioSessionActivationAttemptID == activationAttemptID/);
  assert.match(watchModel, /audioSessionActivationRequestOutstanding = true/);
  assert.match(watchModel, /reason=previous_native_request_outstanding/);
  assert.match(watchModel, /finishStaleAudioSessionActivation/);
  assert.match(watchModel, /deferredAudioSessionDeactivationRequired = true/);
  assert.match(
    watchModel,
    /if audioSessionActivationRequestOutstanding \{[\s\S]*code: "audio_session_deactivation_deferred"[\s\S]*\} else \{[\s\S]*setActive\(/,
  );
  const staleActivationHandler = watchModel.slice(
    watchModel.indexOf("private func finishStaleAudioSessionActivation"),
    watchModel.indexOf("private func observeAudioSessionEvents"),
  );
  assert.match(staleActivationHandler, /setActive\(/);
  assert.match(staleActivationHandler, /guard !mediaServicesAreLost/);
  assert.ok(
    staleActivationHandler.indexOf("setActive(") <
      staleActivationHandler.indexOf("deferredAudioSessionPreparation()"),
    "a stale successful activation must be scrubbed before the deferred current activation begins",
  );
  assert.match(watchModel, /session\.activate\(options: \[\]\)/);
  assert.doesNotMatch(watchModel, /audioSessionActivationQueue/);
  assert.match(watchModel, /reason: "session_activation"/);
  assert.match(watchModel, /reason: "debug_probe_session_activation"/);
  assert.match(watchModel, /AVAudioSession\.routeChangeNotification/);
  assert.match(watchModel, /AVAudioSession\.interruptionNotification/);
  assert.match(watchModel, /AVAudioSession\.mediaServicesWereLostNotification/);
  assert.match(watchModel, /AVAudioSession\.mediaServicesWereResetNotification/);
  assert.match(watchModel, /code: "audio_session_event"/);
  assert.match(watchModel, /input_routes=/);
  assert.match(watchModel, /output_routes=/);
  assert.match(watchModel, /private var mediaServicesAreLost = false/);
  assert.match(watchModel, /private var audioRecoveryGeneration = 0/);
  assert.match(watchModel, /func handleMediaServicesWereLost\(source: String\)/);
  assert.match(watchModel, /func handleMediaServicesWereReset\(\)/);
  assert.match(watchModel, /AVAudioSession\.ErrorCode\.mediaServicesFailed\.rawValue/);
  assert.match(watchModel, /source\.code == -308/);
  assert.match(watchModel, /capture\.invalidateAfterMediaServicesLoss\(\)/);
  assert.match(watchModel, /audioPlayer\.invalidateAfterMediaServicesLoss\(\)/);
  assert.match(watchModel, /duplexAudioEngine\.discardAfterMediaServicesLoss\(\)/);
  assert.match(watchModel, /duplexAudioEngine\.rebuildFreshGraph\(\)/);
  assert.match(watchModel, /code: "audio_recovery_waiting_for_reset"/);
  assert.match(watchModel, /code: "audio_recovery_reactivation_started"/);
  assert.match(watchModel, /code: "audio_recovery_reactivated"/);
  assert.match(watchModel, /code: "audio_graph_recreated"/);
  assert.match(watchModel, /code: "audio_graph_discarded"/);
  assert.match(watchModel, /guard audioSessionIsActive else \{\s*activateAudioSessionForPendingRecording\(\)/);
  assert.match(watchModel, /code: "audio_resume_activation_started"/);
  assert.match(watchModel, /code: "audio_resume_activated"/);
  assert.match(
    watchModel,
    /func presentTerminalAudioFailure[\s\S]*audioPlayer\.shutdown\(\)[\s\S]*deactivateAudioSessionAfterFailure\(reason: reason\)[\s\S]*guard !mediaServicesAreLost/,
  );
  assert.match(
    watchModel,
    /func deactivateAudioSessionAfterFailure[\s\S]*guard !mediaServicesAreLost[\s\S]*if audioSessionActivationRequestOutstanding[\s\S]*cancelPendingAudioSessionActivation\(\)[\s\S]*setActive\(/,
  );
  assert.match(watchModel, /code: "audio_session_deactivated_after_failure"/);
  assert.match(watchModel, /stage: "deactivate_after_failure"/);
  assert.match(watchModel, /CaptureStartRecoveryPolicy\.decision/);
  assert.match(watchModel, /code: "audio_recovery_scheduled"/);
  assert.match(watchModel, /delayMilliseconds/);
  assert.match(watchModel, /responseInFlight: phase == \.thinking \|\| phase == \.speaking/);
  assert.match(watchModel, /response_cancelled=0/);
  assert.match(watchModel, /code: "barge_in_capture_unavailable"/);
  assert.match(watchModel, /provider_response_preserved=1/);
  assert.match(watchModel, /setActive\(\s*false,[\s\S]*notifyOthersOnDeactivation/);
  assert.match(capture, /code: "capture_attempt"/);
  assert.match(capture, /private var captureGeneration = 0/);
  assert.match(capture, /captureGeneration &\+= 1/);
  assert.match(capture, /isCurrentCaptureGeneration\(generation\)/);
  assert.match(capture, /isCurrentCaptureAttempt\(attempt\)/);
  assert.match(capture, /let hardwareFormat = input\.inputFormat\(forBus: 0\)/);
  assert.match(capture, /let prestartInputFormat = input\.outputFormat\(forBus: 0\)/);
  assert.ok(
    capture.indexOf("throw AudioCaptureError.invalidInputFormat") <
      capture.indexOf("input.installTap"),
    "a zero-rate or zero-channel input must typed-fail before tap installation",
  );
  assert.match(capture, /installTap\([\s\S]*onBus: 0,[\s\S]*bufferSize: 1_024,[\s\S]*format: nil/);
  assert.match(capture, /let inputFormat = buffer\.format/);
  assert.match(capture, /AVAudioConverter\([\s\S]*from: inputFormat,[\s\S]*to: outputFormat/);
  assert.match(capture, /code: "input_format_negotiated"/);
  assert.match(capture, /code: "input_format"/);
  assert.match(capture, /stage = "input_format"/);
  assert.match(capture, /stage = "tap_install"/);
  assert.match(capture, /stage = "engine_start_preflight"/);
  assert.match(capture, /stage = "engine_start"/);
  assert.match(capture, /code: "audio_graph_prestart"/);
  assert.match(capture, /validateVoiceProcessingGraph\(graph\)/);
  assert.match(capture, /code: "first_buffer_timeout"/);
  assert.match(capture, /error_domain=/);
  assert.match(player, /code: "output_first_buffer"/);
  assert.match(player, /setVoiceProcessingEnabled\(true\)/);
  assert.doesNotMatch(player, /setVoiceProcessingEnabled\(false\)/);
  assert.match(player, /let inputNodeInputFormat = input\.inputFormat\(forBus: 0\)/);
  assert.match(player, /let inputNodeOutputFormat = input\.outputFormat\(forBus: 0\)/);
  assert.match(player, /let outputNodeInputFormat = output\.inputFormat\(forBus: 0\)/);
  assert.match(player, /let outputNodeOutputFormat = output\.outputFormat\(forBus: 0\)/);
  assert.match(player, /inputVoiceProcessingEnabled: input\.isVoiceProcessingEnabled/);
  assert.match(player, /outputVoiceProcessingEnabled: output\.isVoiceProcessingEnabled/);
  assert.match(
    player,
    /criticalIOFormatsMatch: inputNodeOutputFormat\.isEqual\(\s*outputNodeInputFormat\s*\)/,
  );
  assert.match(
    player,
    /playerOutputMatchesOutputInput: playerOutputFormat\.map \{[\s\S]*?\$0\.isEqual\(outputNodeInputFormat\)/,
  );
  assert.match(player, /inputNodeOutputFormat,[\s\S]*outputNodeInputFormat/);
  assert.match(player, /stage: "after_voice_processing"/);
  assert.match(player, /stage: "after_direct_connection"/);
  assert.match(player, /stage: "after_prepare"/);
  assert.match(player, /stage: "immediately_before_start"/);
  assert.doesNotMatch(player, /matchesExactly/);
  assert.doesNotMatch(
    player,
    /channelLayoutSignature\(lhs\) == Self\.channelLayoutSignature\(rhs\)/,
  );
  assert.match(player, /input_node_input_format=/);
  assert.match(player, /input_node_output_format=/);
  assert.match(player, /output_node_input_format=/);
  assert.match(player, /output_node_output_format=/);
  assert.match(player, /player_output_format=/);
  assert.match(player, /asbd_reserved=/);
  assert.match(player, /common=%u,interleaved=%d,standard=%d/);
  assert.match(player, /value\.mFormatID == kAudioFormatLinearPCM/);
  assert.match(player, /value\.mReserved == 0/);
  assert.match(player, /invalidIOFormat\(stage:/);
  assert.match(player, /func prepareForStart\(\) throws -> WatchAudioGraphDescription/);
  assert.match(player, /func validateVoiceProcessingGraph\(/);
  assert.match(player, /func discardAfterMediaServicesLoss\(\)/);
  assert.match(player, /func rebuildFreshGraph\(\) -> Int/);
  assert.match(
    player,
    /AVAudioConverter\([\s\S]*from: wireFormat,[\s\S]*to: negotiatedPlaybackFormat/,
  );
  assert.match(player, /engine\.connect\(player, to: output, format: requestedPlaybackFormat\)/);
  assert.doesNotMatch(player, /mainMixerNode/);
  assert.ok(
    player.indexOf("setVoiceProcessingEnabled(true)") < player.indexOf("engine.attach(player)") &&
      player.indexOf("engine.attach(player)") < player.indexOf("engine.connect(player, to: output"),
    "voice processing must be enabled and snapshotted before the fresh player is attached and connected",
  );
  assert.match(player, /completionCallbackType: \.dataPlayedBack/);
  assert.match(player, /sourceByteOffset == data\.count/);
  assert.match(player, /func finishPlaybackConversion\(\) throws -> \[AVAudioPCMBuffer\]/);
  assert.match(player, /code: "output_converter_flushed"/);
  assert.match(player, /code: "output_finished"[\s\S]*data_played_back=1/);
  assert.match(player, /source_frames=\\\(sourceFrames\)/);
  assert.match(player, /output_frames=\\\(outputFrames\)/);
  assert.doesNotMatch(player, /engine\.connect\([^\n]+wireFormat/);
  assert.match(player, /code: "output_failed"/);
  assert.match(watchInfo, /<key>UIBackgroundModes<\/key>\s*<array>\s*<string>audio<\/string>/);
  assert.match(watchInfo, /<key>CFBundleShortVersionString<\/key>\s*<string>\$\(MARKETING_VERSION\)<\/string>/);
  assert.match(phoneInfo, /<key>CFBundleShortVersionString<\/key>\s*<string>\$\(MARKETING_VERSION\)<\/string>/);
  assert.doesNotMatch(capture, /setActive\(false/);
  assert.doesNotMatch(player, /setActive\(false/);
  assert.equal(
    (capture.match(/AVAudioEngine\(\)/g) ?? []).length,
    0,
    "capture must not create a competing AVAudioEngine",
  );
  assert.equal(
    (player.match(/AVAudioEngine\(\)/g) ?? []).length,
    1,
    "the shared duplex owner must create exactly one AVAudioEngine",
  );
});

test("privacy-safe Sentry telemetry covers every shipped Codex Voice component", () => {
  const rootPackage = JSON.parse(read("package.json"));
  const relayPackage = JSON.parse(read("relay/package.json"));
  const app = JSON.parse(read("app.json"));
  const project = read("ios/project.yml");
  const phone = read("phoneTelemetry.js");
  const watch = read("ios/App/CodexVoiceWatch/WatchTelemetry.swift");
  const complication = read("ios/App/CodexVoiceComplication/ComplicationTelemetry.swift");
  const bridge = read("Bridge/Sources/CodexVoiceBridge/BridgeTelemetry.swift");
  const relayServer = read("relay/sentry.server.config.ts");
  const relayEdge = read("relay/sentry.edge.config.ts");
  const relayClient = read("relay/instrumentation-client.ts");
  const relayVerifier = read("relay/app/api/observability/verify/route.ts");
  const allTelemetry = [phone, watch, complication, bridge, relayServer, relayEdge, relayClient].join("\n");

  assert.equal(rootPackage.dependencies["@sentry/react-native"], "8.23.0");
  assert.equal(relayPackage.dependencies["@sentry/nextjs"], "10.71.0");
  assert.ok(
    app.expo.plugins.some(
      (plugin) => Array.isArray(plugin) && plugin[0] === "@sentry/react-native/expo",
    ),
  );
  assert.match(project, /exactVersion: 9\.24\.0/);
  assert.equal(
    (project.match(/product: Sentry-WithoutUIKitOrAppKit/g) ?? []).length,
    2,
    "the Watch app and complication must both link the Watch-safe SDK",
  );
  assert.match(
    project,
    /LD_RUNPATH_SEARCH_PATHS: "\$\(inherited\) @executable_path\/Frameworks"/,
    "the Watch app must search its bundled Frameworks directory at launch",
  );
  assert.match(
    project,
    /LD_RUNPATH_SEARCH_PATHS: "\$\(inherited\) @executable_path\/\.\.\/\.\.\/Frameworks"/,
    "the complication must search the containing Watch app Frameworks directory",
  );
  assert.match(project, /Upload Debug Symbols to Sentry/);
  assert.match(watch, /import SentryWithoutUIKit/);
  assert.match(complication, /import SentryWithoutUIKit/);
  assert.match(bridge, /import Sentry/);
  assert.equal(
    ([watch, complication, bridge].join("\n").match(/sendDefaultPii\s*=\s*false/g) ?? []).length,
    3,
    "every Cocoa component must explicitly disable default PII",
  );
  assert.doesNotMatch(allTelemetry, /attachScreenshot\s*[:=]\s*true/);
  assert.doesNotMatch(allTelemetry, /attachViewHierarchy\s*[:=]\s*true/);
  assert.doesNotMatch(allTelemetry, /transcript|audio_data|pcm_bytes.*Sentry/i);
  for (const cocoaConfig of [watch, complication, bridge]) {
    assert.match(cocoaConfig, /user\.ipAddress = "0\.0\.0\.0"/);
    assert.match(cocoaConfig, /options\.enableNetworkBreadcrumbs = false/);
    assert.match(cocoaConfig, /options\.enableNetworkTracking = false/);
    assert.match(cocoaConfig, /options\.beforeSendLog = \{ log in/);
    assert.match(cocoaConfig, /options\.beforeSendSpan = \{ span in/);
    assert.match(cocoaConfig, /log\.setAttribute\(nil, forKey: "user\.id"\)/);
    assert.match(cocoaConfig, /scope\.setUser\(noGeolocationUser\(\)\)/);
    assert.match(cocoaConfig, /options\.beforeSend = \{ event in/);
    assert.match(cocoaConfig, /tags\.removeValue\(forKey: "app\.device"\)/);
    assert.match(cocoaConfig, /context\.removeValue\(forKey: "culture"\)/);
    assert.match(cocoaConfig, /app\.removeValue\(forKey: "device_app_hash"\)/);
    assert.match(cocoaConfig, /event\.request = nil/);
  }
  for (const javascriptConfig of [phone, relayServer, relayEdge, relayClient]) {
    assert.match(javascriptConfig, /dataCollection: privateDataCollection/);
    assert.match(javascriptConfig, /userInfo: false/);
    assert.match(javascriptConfig, /cookies: false/);
    assert.match(javascriptConfig, /httpHeaders: \{ request: false, response: false \}/);
    assert.match(javascriptConfig, /httpBodies: \[\]/);
    assert.match(javascriptConfig, /urlQueryParams: false/);
    assert.match(javascriptConfig, /stackFrameVariables: false/);
  }
  for (const relayConfig of [relayServer, relayEdge, relayClient]) {
    assert.match(relayConfig, /noGeolocationUser = \{ ip_address: "0\.0\.0\.0" \}/);
    assert.match(relayConfig, /event\.user = noGeolocationUser/);
    assert.match(relayConfig, /Sentry\.setUser\(noGeolocationUser\)/);
  }
  assert.match(relayVerifier, /CODEX_VOICE_SENTRY_VERIFICATION_TOKEN/);
  assert.match(relayVerifier, /timingSafeEqual/);
  assert.match(relayVerifier, /export async function POST/);
  assert.match(relayVerifier, /forceTransaction: true/);
  assert.match(relayVerifier, /op: "telemetry\.verify"/);
  assert.match(relayVerifier, /Relay telemetry verification log/);
  assert.match(relayVerifier, /Controlled relay Sentry verification event/);
  assert.match(relayVerifier, /CodexVoice\.RelayTelemetryVerification/);
  assert.match(relayVerifier, /Sentry\.captureException/);
  assert.match(relayVerifier, /Sentry\.flush\(5_000\)/);
  assert.doesNotMatch(relayVerifier, /request\.(?:json|text|formData)\(/);
  assert.doesNotMatch(
    relayVerifier,
    /transcript|audio_data|audio_bytes|pcm_bytes|pairing_secret/i,
  );
});

test("Watch voice is automatic, silence-delimited, and interruptible", () => {
  const watchModel = read("ios/App/CodexVoiceWatch/VoiceSessionModel.swift");
  const capture = read("ios/App/CodexVoiceWatch/WatchAudioCapture.swift");
  const watchUI = read("ios/App/CodexVoiceWatch/ContentView.swift");
  const detector = read("Bridge/Sources/CodexVoiceProtocol/AutomaticSpeechTurnDetector.swift");
  const bridgeSession = read("Bridge/Sources/CodexVoiceBridge/BridgeSession.swift");

  assert.match(capture, /AutomaticSpeechTurnDetector/);
  assert.match(capture, /onSpeechStarted/);
  assert.match(capture, /onSpeechEnded/);
  assert.match(detector, /endSilenceSamples/);
  assert.match(detector, /minimumStartRMS: Double = 180/);
  assert.match(watchModel, /startRecordingIfRequested/);
  assert.match(watchModel, /beginBargeInMonitoring/);
  assert.match(watchModel, /ResponseBargeInGate/);
  assert.match(watchModel, /playbackEchoMatch\(for: preRoll\)/);
  assert.match(detector, /PlaybackEchoMatcher/);
  assert.match(detector, /maximumNormalizedCorrelation/);
  assert.match(watchModel, /responseBargeInGate\.committed\(\)/);
  assert.match(watchModel, /responseBargeInGate\.receivedFirstAudio\(\)/);
  assert.match(watchModel, /responseBargeInGate\.rearmedDetector\(\)/);
  assert.match(watchModel, /responseBargeInGate\.isCurrentDetectorEpoch\(detectorEpoch\)/);
  assert.match(watchModel, /case \.ignoreBeforeOutput:/);
  assert.match(watchModel, /case \.interruptPlayback:/);
  assert.match(watchModel, /code: "pre_output_speech_ignored"/);
  assert.match(watchModel, /code: "provider_first_audio_received"/);
  assert.match(watchModel, /code: "initial_playback_speech_deferred"/);
  assert.match(watchModel, /code: "playback_echo_speech_rejected"/);
  assert.match(watchModel, /code: "playback_barge_in_triggered"/);
  assert.match(watchModel, /code: "stale_barge_in_speech_discarded"/);
  assert.match(watchModel, /code: "audio_turn_commit_enqueued"/);
  assert.match(watchModel, /callback_delivery=main_queue_fifo final_audio_ordered=1/);
  assert.match(watchModel, /code: "audio_capture_prewarmed"/);
  const orderedCaptureCallbacks = watchModel.slice(
    watchModel.indexOf("private func beginRecording("),
    watchModel.indexOf("private func handleAudioFailure("),
  );
  assert.match(orderedCaptureCallbacks, /DispatchQueue\.main\.async/);
  assert.doesNotMatch(orderedCaptureCallbacks, /Task \{ @MainActor/);
  assert.ok(
    watchModel.indexOf("guard audioPlayer.enqueue(audio) else { return }") <
      watchModel.indexOf("responseBargeInGate.receivedFirstAudio()"),
    "playback barge-in must arm only after the first response chunk is accepted for local playback",
  );
  assert.doesNotMatch(
    watchModel,
    /phase == \.thinking[\s\S]{0,160}WireEnvelope\(kind: \.stop/,
  );
  assert.match(watchModel, /role: "watch\.capture"/);
  assert.match(watchModel, /code: "no_speech"/);
  assert.match(bridgeSession, /commit_accepted/);
  assert.match(bridgeSession, /first_chunk/);
  assert.match(watchUI, /RelayPulse/);
  assert.match(watchUI, /Image\("RelayPulse"\)/);
  assert.doesNotMatch(watchUI, /TimelineView|minimumInterval|VoiceOrb|ChatGPT/);
  assert.match(watchUI, /model\.toggleMute/);
  assert.match(watchUI, /model\.endSession/);
  assert.doesNotMatch(
    watchUI,
    /Text\("(?:Speak naturally|Speak to interrupt|Listening|Thinking|Speaking|Tap to send|Tap to talk)/i,
  );
  assert.doesNotMatch(watchUI, /toggleRecording|Transcrib/i);
});

test("Watch uses one original relay pulse without a custom frame loop", () => {
  const watchUI = read("ios/App/CodexVoiceWatch/ContentView.swift");
  const contents = read("ios/App/CodexVoiceWatch/Assets.xcassets/RelayPulse.imageset/Contents.json");

  assert.match(contents, /RelayPulse\.jpg/);
  assert.match(watchUI, /Image\("RelayPulse"\)/);
  assert.match(watchUI, /\.clipShape\(Circle\(\)\)/);
  assert.doesNotMatch(watchUI, /TimelineView|frameName\(|timeIntervalSinceReferenceDate/);
  assert.doesNotMatch([contents, watchUI].join("\n"), /ChatGPT|OpenAI|VoiceOrb/);
});

test("Watch voice UI is headerless and recovery is a native-size icon control", () => {
  const watchUI = read("ios/App/CodexVoiceWatch/ContentView.swift");

  assert.doesNotMatch(watchUI, /CodexProductLockup/);
  assert.doesNotMatch(watchUI, /Text\("Codex"\)/);
  assert.match(watchUI, /ProgressView\(\)/);
  assert.match(watchUI, /systemName: "arrow\.clockwise"/);
  assert.match(watchUI, /size: 44/);
  assert.match(watchUI, /accessibilityLabel: actionLabel/);
});

test("Watch complication uses a native relay symbol and refreshes without reinstalling", () => {
  const complication = read("ios/App/CodexVoiceComplication/CodexVoiceComplication.swift");
  const watchApp = read("ios/App/CodexVoiceWatch/CodexVoiceWatchApp.swift");
  const project = read("ios/project.yml");
  assert.match(complication, /Image\(systemName: "waveform"\)/);
  assert.match(complication, /Text\("Relay"\)/);
  assert.match(complication, /Text\("Voice agent"\)/);
  assert.match(complication, /configurationDisplayName\("Pedro Voice Agent"\)/);
  assert.match(complication, /policy: \.after\(refresh\)/);
  assert.match(complication, /\.foregroundStyle\(\.white\)/);
  assert.match(complication, /\.widgetAccentable\(\)/);
  assert.match(complication, /\.contentMarginsDisabled\(\)/);
  assert.match(watchApp, /WidgetCenter\.shared\.reloadTimelines/);
  assert.match(watchApp, /CodexVoiceTalkComplication/);
  assert.doesNotMatch(complication, /AccessoryWidgetBackground/);
  assert.doesNotMatch(complication, /CodexComplicationGlyph|CodexTerminalGlyph/);
  assert.doesNotMatch(complication, /Tap to|Text\("Talk"\)/);
  assert.doesNotMatch(complication, />_/);
  assert.doesNotMatch(complication, /Image\("CodexIcon"\)/);
  assert.doesNotMatch(complication, /Image\("CodexComplicationMark"\)/);
  assert.doesNotMatch(complication, /\.widgetLabel|\.foregroundStyle\(\.primary\)/);
  assert.match(complication, /#Preview\("Relay circular", as: \.accessoryCircular\)/);
  assert.match(complication, /#Preview\("Relay corner", as: \.accessoryCorner\)/);
  assert.match(complication, /#Preview\("Relay rectangular", as: \.accessoryRectangular\)/);
  assert.match(complication, /#Preview\("Relay inline", as: \.accessoryInline\)/);
  assert.doesNotMatch(project, /Shared\/CodexAssets\.xcassets/);
});

test("Apple clients recover when a relay-ready handshake packet is dropped", () => {
  const bridge = read("ios/Shared/BridgeConnection.swift");
  const watchModel = read("ios/App/CodexVoiceWatch/VoiceSessionModel.swift");

  assert.match(bridge, /scheduleSecureResponseTimeout/);
  assert.match(bridge, /secure response timed out/);
  assert.match(bridge, /connectionFailed\(expectedTask/);
  assert.match(watchModel, /requestBackendStart/);
  assert.match(watchModel, /Still connecting through OpenRouter/);
  assert.match(watchModel, /Retrying OpenRouter securely/);
});

test("relay-to-Watch delivery is size-safe, correlated, acknowledged, and observable", () => {
  const protocol = read("Bridge/Sources/CodexVoiceProtocol/WireEnvelope.swift");
  const secureProtocol = read("Bridge/Sources/CodexVoiceProtocol/SecureBridgeProtocol.swift");
  const bridgeConnection = read("ios/Shared/BridgeConnection.swift");
  const watchModel = read("ios/App/CodexVoiceWatch/VoiceSessionModel.swift");
  const watchTelemetry = read("ios/App/CodexVoiceWatch/WatchTelemetry.swift");
  const bridgeSession = read("Bridge/Sources/CodexVoiceBridge/BridgeSession.swift");
  const relayClient = read("Bridge/Sources/CodexVoiceBridge/RelayHostClient.swift");
  const relay = read("relay-worker/src/index.ts");
  const relayProtocol = read("relay-worker/src/protocol.ts");

  assert.match(protocol, /public var deliveryId: String\?/);
  assert.match(protocol, /public var sequence: Int\?/);
  assert.match(protocol, /public var deliveryOutcome: String\?/);
  assert.match(protocol, /public var turnId: String\?/);
  assert.match(protocol, /public var turnSequence: Int\?/);
  assert.match(protocol, /public var finalAudioSequence: Int\?/);
  assert.match(protocol, /reliable-audio-turn-v1/);
  assert.match(protocol, /public struct ReliableAudioTurnBuffer/);
  assert.match(protocol, /public struct ReliableAudioTurnReceiver/);
  assert.match(secureProtocol, /public var deliveryId: String\?/);
  assert.match(secureProtocol, /public var sequence: Int\?/);
  assert.match(bridgeConnection, /maximumWebSocketMessageBytes = 2 \* 1_024 \* 1_024/);
  assert.match(bridgeConnection, /task\.maximumMessageSize = Self\.maximumWebSocketMessageBytes/);
  assert.match(bridgeConnection, /code: "websocket_receive_failed"/);
  assert.match(bridgeConnection, /code: "secure_envelope_received"/);
  assert.match(bridgeConnection, /code: "delivery_ack_timeout"/);
  assert.match(bridgeConnection, /code: "delivery_pending_cancelled"/);
  assert.match(bridgeConnection, /role: "device\.delivery"/);
  assert.match(bridgeConnection, /audio_turn_replay_started/);
  assert.match(bridgeConnection, /audio_turn_delivery_completed/);
  assert.match(bridgeConnection, /bridge_capability_unavailable/);
  assert.match(bridgeConnection, /onAudioTurnDeliveryFailed/);
  assert.match(watchModel, /watch_handler_unavailable/);
  assert.match(watchModel, /outcome = "audio_enqueued"/);
  assert.match(watchModel, /outcome = "audio_enqueue_rejected"/);
  assert.match(watchTelemetry, /func recordTransport/);
  assert.match(watchTelemetry, /"maximum_message_bytes"/);
  assert.match(watchTelemetry, /"delivery_latency_ms"/);
  assert.match(watchTelemetry, /"audio_queue_depth"/);
  assert.match(watchTelemetry, /"audio_replay_count"/);
  assert.match(bridgeSession, /watch_delivery_acknowledged/);
  assert.match(bridgeSession, /watch_delivery_ack_timeout/);
  assert.match(bridgeSession, /role: "bridge\.delivery"/);
  assert.match(bridgeSession, /watch_audio_chunk_duplicate/);
  assert.match(bridgeSession, /watch_audio_commit_deferred/);
  assert.match(bridgeSession, /"audio_turn_id": turnID/);
  assert.match(bridgeSession, /return "commit_duplicate"/);
  assert.match(relayClient, /task\.maximumMessageSize = Self\.maximumWebSocketMessageBytes/);
  assert.match(relay, /ctx\.acceptWebSocket\(server\)/);
  assert.match(relay, /serializeAttachment/);
  assert.match(relay, /hibernation_eligible: true/);
  assert.match(relay, /websocket_send_completed/);
  assert.match(relay, /frame_delivery_attempted/);
  assert.match(relay, /Sentry\.logger\.info/);
  assert.match(relayProtocol, /MAX_FRAME_BYTES = 1_500_000/);
  assert.doesNotMatch(relay, /setInterval|setTimeout/);
  assert.doesNotMatch(
    [watchTelemetry, bridgeSession, relay, relayProtocol].join("\n"),
    /["'](?:transcript|audio_data|audio_bytes|pcm_bytes|pairing_secret)["']\s*:/i,
  );
});

test("the Expo companion uses an independent relay identity and honest connection states", () => {
  const companion = read("App.js");
  const app = JSON.parse(read("app.json"));

  assert.equal(app.expo.name, "Pedro Voice Agent");
  assert.match(companion, /require\('\.\/ios\/Shared\/RelayAssets\.xcassets\/RelayIcon\.imageset\/RelayIcon\.png'\)/);
  assert.match(companion, /Designed and built by Pedro Villanueva\./);
  assert.match(companion, /Connecting securely/);
  assert.match(companion, /Ready on Apple Watch/);
  assert.match(companion, /Mac paired · Watch pending/);
  assert.doesNotMatch(companion, />_|ChatGPT|Codex on your Watch|Codex Voice/);
});
