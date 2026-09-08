import * as Sentry from '@sentry/react-native';
import {
  _INTERNAL_captureLog,
  _INTERNAL_captureSerializedLog,
} from '@sentry/core';
import { Settings } from 'react-native';

const dsn = 'https://a56304d3eee012e306ef36a869aa66e2@o4509707257905152.ingest.us.sentry.io/4511973556617216';
const verificationSetting = Settings.get('CodexVoiceSentryVerification');
const verificationEnabled = verificationSetting === true
  || verificationSetting === 'YES'
  || verificationSetting === '1';
const noGeolocationUser = { ip_address: '0.0.0.0' };
const privateDataCollection = {
  userInfo: false,
  cookies: false,
  httpHeaders: { request: false, response: false },
  httpBodies: [],
  urlQueryParams: false,
  graphQL: { document: false, variables: false },
  genAI: { inputs: false, outputs: false },
  databaseQueryData: false,
  stackFrameVariables: false,
};

function sanitizeEvent(event) {
  event.user = noGeolocationUser;
  if (event.tags) delete event.tags['app.device'];
  if (event.contexts) {
    delete event.contexts.culture;
    if (event.contexts.app) delete event.contexts.app.device_app_hash;
    if (event.contexts.device) delete event.contexts.device.locale;
  }
  delete event.request;
  return event;
}

Sentry.init({
  dsn,
  environment: __DEV__ ? 'development' : 'production',
  dataCollection: privateDataCollection,
  attachScreenshot: false,
  attachViewHierarchy: false,
  enableLogs: true,
  logsOrigin: 'all',
  enableAutoConsoleLogs: false,
  tracesSampleRate: 1.0,
  tracePropagationTargets: [],
  enableAppHangTracking: true,
  debug: verificationEnabled,
  beforeSend(event) {
    // A non-routable sentinel prevents Relay from deriving GeoIP data. The
    // project-side IP scrubber removes the sentinel before storage.
    if (verificationEnabled) {
      console.info('Codex Voice iPhone Sentry prepared error');
    }
    return sanitizeEvent(event);
  },
  beforeSendLog(log) {
    if (verificationEnabled) {
      console.info('Codex Voice iPhone Sentry prepared log');
    }
    if (log.attributes) {
      delete log.attributes['user.id'];
      delete log.attributes['user.name'];
      delete log.attributes['user.email'];
    }
    return log;
  },
  beforeSendSpan(span) {
    if (verificationEnabled) {
      console.info('Codex Voice iPhone Sentry prepared span');
    }
    if (span.data) {
      delete span.data['user.id'];
      delete span.data['user.name'];
      delete span.data['user.email'];
      delete span.data['url.query'];
      delete span.data['http.request.header.authorization'];
    }
    return span;
  },
});
Sentry.setUser(noGeolocationUser);
Sentry.setTag('component', 'iphone');

function capturePhoneLog(level, message, attributes = {}) {
  _INTERNAL_captureLog(
    { level, message, attributes },
    Sentry.getCurrentScope(),
    (client, serializedLog) => {
      // Hermes can expose a stale performance.timeOrigin. Preserve Sentry's
      // normal log processing, but use the wall clock for the serialized item.
      _INTERNAL_captureSerializedLog(client, {
        ...serializedLog,
        timestamp: Date.now() / 1_000,
      });
    },
  );
}

capturePhoneLog('info', 'Codex Voice component started', { component: 'iphone' });

function wallClockSpan(name, op, operation, attributes = {}) {
  return Sentry.startSpanManual(
    {
      name,
      op,
      startTime: Date.now(),
      attributes: {
        component: 'iphone',
        ...attributes,
      },
    },
    (span) => {
      let result;
      try {
        result = operation();
      } catch (error) {
        span.setStatus({ code: 2, message: 'internal_error' });
        span.end(Date.now());
        throw error;
      }
      return Promise.resolve(result).then(
        (value) => {
          span.end(Date.now());
          return value;
        },
        (error) => {
          span.setStatus({ code: 2, message: 'internal_error' });
          span.end(Date.now());
          throw error;
        },
      );
    },
  );
}

async function emitControlledVerification() {
  await wallClockSpan(
    'iphone.telemetry.verification',
    'telemetry.verify',
    async () => {
      capturePhoneLog('info', 'iPhone telemetry verification log', {
        component: 'iphone',
        verification: true,
      });
      const verificationError = new Error('Controlled iPhone Sentry verification event');
      verificationError.name = 'CodexVoice.PhoneTelemetryVerification';
      const eventID = Sentry.captureException(verificationError, {
        tags: {
          component: 'iphone',
          operation: 'telemetry_verification',
          verification: 'true',
        },
      });
      console.info(`Codex Voice iPhone Sentry verification event_id=${eventID}`);
      await new Promise((resolve) => setTimeout(resolve, 5));
    },
    { verification: true },
  );
  const flushed = await Sentry.flush(5_000);
  console.info(`Codex Voice iPhone Sentry verification flushed=${flushed ? 1 : 0}`);
}

if (verificationEnabled) {
  void emitControlledVerification();
}

export function phoneStage(code, attributes = {}) {
  capturePhoneLog('info', 'iPhone pairing stage completed', {
    component: 'iphone',
    code,
    ...attributes,
  });
}

export function capturePhoneFailure(code, error) {
  const errorName = error instanceof Error ? error.name : 'UnknownError';
  capturePhoneLog('error', 'iPhone pairing operation failed', {
    component: 'iphone',
    code,
    error_name: errorName,
  });
  const sanitized = new Error('iPhone pairing operation failed');
  sanitized.name = errorName;
  Sentry.captureException(sanitized, {
    tags: {
      component: 'iphone',
      operation: code,
    },
  });
}

export function tracePhoneOperation(code, operation) {
  return wallClockSpan('iphone.' + code, 'ui.action', operation);
}

export { Sentry };
