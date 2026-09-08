module.exports = {
  sourceSkips: ["PackageJsonScriptsAll"],
  ignorePaths: [
    "scripts/publish-ios-update.sh",
    "scripts/build-ios-local.sh",
    "ios/*.xcworkspace/**",
    "ios/Pods/**",
    "ios/build/**",
    "ios/.xcode.env.local",
  ],
  extraSources: [
    {
      type: "dir",
      filePath: "Bridge/Sources/CodexVoiceProtocol",
      reasons: ["codexVoiceSharedProtocol"],
    },
  ],
};
