const { getSentryExpoConfig } = require('@sentry/react-native/metro');

module.exports = getSentryExpoConfig(__dirname, {
  includeWebFeedback: false,
  includeWebReplay: false,
});
