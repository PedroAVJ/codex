import * as Sentry from "@sentry/nextjs";

const dsn =
  process.env.SENTRY_DSN ??
  "https://a56304d3eee012e306ef36a869aa66e2@o4509707257905152.ingest.us.sentry.io/4511973556617216";
const noGeolocationUser = { ip_address: "0.0.0.0" };
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

Sentry.init({
  dsn,
  environment: process.env.VERCEL_ENV ?? process.env.NODE_ENV ?? "production",
  release: process.env.SENTRY_RELEASE ?? process.env.VERCEL_GIT_COMMIT_SHA,
  dataCollection: privateDataCollection,
  tracesSampleRate: 1.0,
  enableLogs: true,
  beforeSend(event) {
    delete event.request;
    event.user = noGeolocationUser;
    return event;
  },
  beforeSendLog(log) {
    delete log.attributes?.["user.id"];
    delete log.attributes?.["user.name"];
    delete log.attributes?.["user.email"];
    return log;
  },
  beforeSendSpan(span) {
    delete span.data?.["user.id"];
    delete span.data?.["user.name"];
    delete span.data?.["user.email"];
    delete span.data?.["url.query"];
    delete span.data?.["http.request.header.authorization"];
    return span;
  },
});

Sentry.setUser(noGeolocationUser);
Sentry.setTag("component", "relay");
Sentry.logger.info("Codex Voice component started", {
  component: "relay",
  runtime: "edge",
});
