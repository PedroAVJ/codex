import * as Sentry from "@sentry/nextjs";

type RelayAttributes = Record<string, string | number | boolean>;

function runtimeLog(
  level: "info" | "warn" | "error",
  message: string,
  attributes: RelayAttributes,
) {
  const line = JSON.stringify({
    level,
    message,
    timestamp: new Date().toISOString(),
    ...attributes,
  });
  if (level === "error") console.error(line);
  else if (level === "warn") console.warn(line);
  else console.log(line);
}

export function relayStage(code: string, attributes: RelayAttributes = {}) {
  const values = {
    component: "relay",
    code,
    ...attributes,
  };
  runtimeLog("info", "Codex Voice relay stage completed", values);
  Sentry.logger.info("Codex Voice relay stage completed", values);
}

export function relayWarning(code: string, attributes: RelayAttributes = {}) {
  const values = {
    component: "relay",
    code,
    ...attributes,
  };
  runtimeLog("warn", "Codex Voice relay warning", values);
  Sentry.logger.warn("Codex Voice relay warning", values);
}

export function relayFailure(
  code: string,
  error: unknown,
  attributes: RelayAttributes = {},
) {
  const errorName = error instanceof Error ? error.name : "UnknownError";
  const values = {
    component: "relay",
    code,
    error_name: errorName,
    ...attributes,
  };
  runtimeLog("error", "Codex Voice relay operation failed", values);
  Sentry.logger.error("Codex Voice relay operation failed", values);
  const sanitized = new Error("Codex Voice relay operation failed");
  sanitized.name = errorName;
  Sentry.captureException(sanitized, {
    tags: {
      component: "relay",
      operation: code,
    },
    extra: attributes,
  });
}

export function traceRelayOperation<T>(code: string, operation: () => Promise<T>): Promise<T> {
  return Sentry.startSpan(
    { name: `relay.${code}`, op: "relay.transport" },
    operation,
  );
}
