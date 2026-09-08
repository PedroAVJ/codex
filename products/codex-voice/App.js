import { CameraView, useCameraPermissions } from 'expo-camera';
import { StatusBar } from 'expo-status-bar';
import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import {
  capturePhoneFailure,
  phoneStage,
  Sentry,
  tracePhoneOperation,
} from './phoneTelemetry';
import {
  ActivityIndicator,
  Alert,
  Image,
  Modal,
  NativeEventEmitter,
  NativeModules,
  Pressable,
  SafeAreaView,
  ScrollView,
  StyleSheet,
  Text,
  View,
} from 'react-native';

const nativeCompanion = NativeModules.CodexVoiceNative;
const relayMark = require('./ios/Shared/RelayAssets.xcassets/RelayIcon.imageset/RelayIcon.png');
const initialState = {
  phase: 'unpaired',
  status: 'Loading secure pairing state…',
  errorText: null,
  watchSyncPhase: 'activating',
  watchSyncStatus: 'Preparing Apple Watch sync…',
  watchReady: false,
};

function ActionButton({ children, disabled = false, onPress, secondary = false, destructive = false }) {
  return (
    <Pressable
      accessibilityRole="button"
      disabled={disabled}
      onPress={onPress}
      style={({ pressed }) => [
        styles.button,
        secondary && styles.secondaryButton,
        destructive && styles.destructiveButton,
        disabled && styles.disabledButton,
        pressed && !disabled && styles.pressedButton,
      ]}
    >
      <Text
        style={[
          styles.buttonText,
          secondary && styles.secondaryButtonText,
          destructive && styles.destructiveButtonText,
        ]}
      >
        {children}
      </Text>
    </Pressable>
  );
}

function RelayMark({ size = 72 }) {
  return (
    <Image
      accessibilityIgnoresInvertColors
      accessibilityLabel="Pedro Voice Agent"
      resizeMode="contain"
      source={relayMark}
      style={{ height: size, width: size }}
    />
  );
}

function Scanner({ onClose, onPair }) {
  const [permission, requestPermission] = useCameraPermissions();
  const [didScan, setDidScan] = useState(false);

  useEffect(() => {
    if (permission && !permission.granted && permission.canAskAgain) {
      requestPermission();
    }
  }, [permission, requestPermission]);

  const handleBarcode = useCallback(
    ({ data }) => {
      if (didScan || !data.toLowerCase().startsWith('codexvoice://')) {
        return;
      }
      setDidScan(true);
      onPair(data);
    },
    [didScan, onPair]
  );

  return (
    <SafeAreaView style={styles.scannerScreen}>
      <StatusBar style="light" />
      {permission?.granted ? (
        <CameraView
          barcodeScannerSettings={{ barcodeTypes: ['qr'] }}
          onBarcodeScanned={didScan ? undefined : handleBarcode}
          style={StyleSheet.absoluteFill}
        />
      ) : (
        <View style={styles.permissionPanel}>
          <Text style={styles.permissionTitle}>Camera access is needed</Text>
          <Text style={styles.permissionText}>
            Pedro Voice Agent only uses the camera to scan the one-time pairing QR shown by your Mac.
          </Text>
          <ActionButton onPress={requestPermission}>Allow camera</ActionButton>
        </View>
      )}
      <View pointerEvents="none" style={styles.scanFrame} />
      <View pointerEvents="none" style={styles.scannerHeader}>
        <View style={styles.scannerBrandMark}>
          <RelayMark size={28} />
        </View>
        <Text style={styles.scannerBrand}>Pedro Voice Agent</Text>
      </View>
      <View style={styles.scannerFooter}>
        <Text style={styles.scannerEyebrow}>SECURE PAIRING</Text>
        <Text style={styles.scannerInstruction}>Center the one-time QR shown by your Mac</Text>
        <ActionButton onPress={onClose} secondary>
          Cancel
        </ActionButton>
      </View>
    </SafeAreaView>
  );
}

function App() {
  const [state, setState] = useState(initialState);
  const [scannerVisible, setScannerVisible] = useState(false);
  const mounted = useRef(true);

  const refresh = useCallback(async () => {
    if (!nativeCompanion) {
      capturePhoneFailure('native_bridge_missing', new Error('Native bridge unavailable'));
      setState({
        phase: 'unpaired',
        status: 'The native pairing bridge is missing from this build.',
        errorText: 'Install a Pedro Voice Agent binary that includes the Expo migration.',
        watchSyncPhase: 'unavailable',
        watchSyncStatus: 'Apple Watch sync is unavailable in this build.',
        watchReady: false,
      });
      return;
    }
    try {
      const nextState = await tracePhoneOperation('state.refresh', () => nativeCompanion.getState());
      if (mounted.current) {
        setState(nextState);
        phoneStage('state_refreshed', {
          phase: nextState.phase,
          watch_sync_phase: nextState.watchSyncPhase,
        });
      }
    } catch (error) {
      capturePhoneFailure('state_refresh', error);
      if (mounted.current) {
        setState((current) => ({ ...current, errorText: error.message }));
      }
    }
  }, []);

  useEffect(() => {
    mounted.current = true;
    refresh();
    if (!nativeCompanion) return () => { mounted.current = false; };

    const emitter = new NativeEventEmitter(nativeCompanion);
    const subscription = emitter.addListener('CodexVoiceStateChanged', (nextState) => {
      phoneStage('native_state_changed', {
        phase: nextState.phase,
        watch_sync_phase: nextState.watchSyncPhase,
      });
      setState(nextState);
    });
    return () => {
      mounted.current = false;
      subscription.remove();
    };
  }, [refresh]);

  const pair = useCallback(async (url) => {
    setScannerVisible(false);
    try {
      const nextState = await tracePhoneOperation(
        'pairing.open_url',
        () => nativeCompanion.openPairingURL(url),
      );
      setState(nextState);
      phoneStage('pairing_completed', { watch_sync_phase: nextState.watchSyncPhase });
    } catch (error) {
      capturePhoneFailure('pairing_open_url', error);
      Alert.alert('Pairing link rejected', error.message || 'Generate a fresh QR on the Mac and try again.');
      refresh();
    }
  }, [refresh]);

  const forget = useCallback(() => {
    Alert.alert(
      'Forget this Mac?',
      'The encrypted pairing credentials will be removed from the iPhone and Apple Watch.',
      [
        { text: 'Cancel', style: 'cancel' },
        {
          text: 'Forget',
          style: 'destructive',
          onPress: async () => {
            try {
              const nextState = await tracePhoneOperation(
                'pairing.forget',
                () => nativeCompanion.forgetMac(),
              );
              setState(nextState);
              phoneStage('pairing_forgotten');
            } catch (error) {
              capturePhoneFailure('pairing_forget', error);
              Alert.alert('Could not forget this Mac', 'Try again after reopening Pedro Voice Agent.');
            }
          },
        },
      ]
    );
  }, []);

  const syncWatch = useCallback(async () => {
    try {
      const nextState = await tracePhoneOperation(
        'watch.resend',
        () => nativeCompanion.resendToWatch(),
      );
      setState(nextState);
      phoneStage('watch_resend_requested', { watch_sync_phase: nextState.watchSyncPhase });
    } catch (error) {
      capturePhoneFailure('watch_resend', error);
      Alert.alert('Apple Watch sync failed', error.message || 'Keep the Watch nearby and try again.');
      refresh();
    }
  }, [refresh]);

  const paired = state.phase === 'paired';
  const connecting = state.phase === 'connecting';
  const watchReady = paired && state.watchReady;
  const watchSyncing = paired && ['activating', 'sending'].includes(state.watchSyncPhase);
  const watchFailed = paired && state.watchSyncPhase === 'failed';
  const statusMark = useMemo(
    () => (watchReady ? '✓' : paired ? '•••' : '—'),
    [paired, watchReady]
  );
  const statusTitle = connecting
    ? 'Connecting securely'
    : !paired
      ? 'Pair your Mac'
    : watchReady
      ? 'Ready on Apple Watch'
      : watchSyncing
        ? 'Sending to Apple Watch'
        : 'Mac paired · Watch pending';
  const statusText = paired
    ? state.watchSyncStatus || 'Send the secure Mac identity to Apple Watch.'
    : state.errorText || state.status;

  return (
    <SafeAreaView style={styles.screen}>
      <StatusBar style="dark" />
      <ScrollView
        alwaysBounceVertical={false}
        contentContainerStyle={styles.content}
        keyboardShouldPersistTaps="handled"
      >
        <View style={styles.hero}>
          <View style={styles.markField}>
            <RelayMark size={74} />
          </View>
          <Text style={styles.eyebrow}>INDEPENDENT WATCH CLIENT</Text>
          <Text style={styles.title}>Voice mode, from your wrist</Text>
          <Text style={styles.subtitle}>
            Pedro Voice Agent securely connects Apple Watch to the coding agent on your Mac. Designed and built by Pedro Villanueva.
          </Text>
        </View>

        <View style={styles.statusCard}>
          <Text style={styles.cardEyebrow}>CONNECTION</Text>
          <View style={styles.statusRow}>
            <View style={[styles.statusMark, watchReady && styles.statusMarkPaired]}>
              {connecting || watchSyncing ? (
                <ActivityIndicator color={colors.ink} />
              ) : (
                <Text style={styles.statusGlyph}>{statusMark}</Text>
              )}
            </View>
            <View style={styles.statusCopy}>
              <Text style={styles.statusTitle}>{statusTitle}</Text>
              <Text style={[styles.statusText, (state.errorText || watchFailed) && styles.errorText]}>
                {statusText}
              </Text>
            </View>
          </View>
          <View style={styles.route} accessibilityLabel="Mac to iPhone to Apple Watch secure setup path">
            <Text style={styles.routeLabel}>Mac</Text>
            <View style={[styles.routeLine, paired && styles.routeLineActive]} />
            <Text style={styles.routeLabel}>iPhone</Text>
            <View style={[styles.routeLine, watchReady && styles.routeLineReady]} />
            <Text style={styles.routeLabel}>Watch</Text>
          </View>
        </View>

        <View style={styles.actions}>
          {paired ? (
            <>
              <ActionButton disabled={watchSyncing || !nativeCompanion} onPress={syncWatch} secondary={watchReady}>
                {watchReady ? 'Send again' : watchSyncing ? 'Sending…' : 'Send to Apple Watch'}
              </ActionButton>
              <ActionButton onPress={() => setScannerVisible(true)} secondary>
                Pair a different Mac
              </ActionButton>
              <ActionButton destructive onPress={forget} secondary>
                Forget this Mac
              </ActionButton>
            </>
          ) : (
            <ActionButton disabled={connecting || !nativeCompanion} onPress={() => setScannerVisible(true)}>
              {connecting ? 'Connecting…' : 'Scan Mac QR'}
            </ActionButton>
          )}
        </View>

        <View style={styles.privacyNote}>
          <View style={styles.privacyDot} />
          <Text style={styles.privacyText}>
            Your API key stays in the Mac Keychain. The QR contains only short-lived encrypted pairing data.
          </Text>
        </View>
      </ScrollView>

      <Modal animationType="slide" onRequestClose={() => setScannerVisible(false)} visible={scannerVisible}>
        <Scanner onClose={() => setScannerVisible(false)} onPair={pair} />
      </Modal>
    </SafeAreaView>
  );
}

const colors = {
  background: '#faf9f7',
  ink: '#141413',
  muted: '#6b6964',
  surface: '#ffffff',
  quiet: '#f1f0ed',
  separator: 'rgba(20,20,19,0.10)',
  success: '#34c759',
  info: '#0a84ff',
  danger: '#ff453a',
};

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background },
  content: { alignSelf: 'center', flexGrow: 1, justifyContent: 'center', maxWidth: 430, paddingBottom: 24, paddingHorizontal: 20, paddingTop: 18, width: '100%' },
  hero: { alignItems: 'center', marginBottom: 20 },
  markField: { alignItems: 'center', height: 82, justifyContent: 'center', marginBottom: 12, width: 82 },
  eyebrow: { color: colors.muted, fontSize: 10, fontWeight: '700', letterSpacing: 1.4, marginBottom: 8 },
  title: { color: colors.ink, fontSize: 32, fontWeight: '700', letterSpacing: -1.05, lineHeight: 36, textAlign: 'center' },
  subtitle: { color: colors.muted, fontSize: 15, fontWeight: '400', lineHeight: 21, marginTop: 9, maxWidth: 350, textAlign: 'center' },
  statusCard: { backgroundColor: colors.surface, borderColor: colors.separator, borderRadius: 14, borderWidth: 1, padding: 16 },
  cardEyebrow: { color: colors.muted, fontSize: 10, fontWeight: '700', letterSpacing: 1.4, marginBottom: 14 },
  statusRow: { alignItems: 'center', flexDirection: 'row' },
  statusMark: { alignItems: 'center', backgroundColor: colors.quiet, borderRadius: 18, height: 36, justifyContent: 'center', width: 36 },
  statusMarkPaired: { backgroundColor: '#e3f5e8' },
  statusGlyph: { color: colors.ink, fontSize: 15, fontWeight: '700', letterSpacing: -0.5 },
  statusCopy: { flex: 1, marginLeft: 12 },
  statusTitle: { color: colors.ink, fontSize: 16, fontWeight: '600', letterSpacing: -0.15 },
  statusText: { color: colors.muted, fontSize: 13, fontWeight: '400', lineHeight: 18, marginTop: 3 },
  errorText: { color: colors.danger },
  route: { alignItems: 'center', borderTopColor: colors.separator, borderTopWidth: 1, flexDirection: 'row', marginTop: 16, paddingTop: 13 },
  routeLabel: { color: colors.muted, fontSize: 10, fontWeight: '600' },
  routeLine: { backgroundColor: colors.separator, flex: 1, height: 1, marginHorizontal: 8 },
  routeLineActive: { backgroundColor: colors.ink },
  routeLineReady: { backgroundColor: colors.success },
  actions: { gap: 10, marginTop: 16 },
  button: { alignItems: 'center', backgroundColor: colors.ink, borderColor: colors.ink, borderRadius: 12, borderWidth: 1, justifyContent: 'center', minHeight: 50, paddingHorizontal: 18 },
  buttonText: { color: '#ffffff', fontSize: 16, fontWeight: '600', letterSpacing: -0.15 },
  secondaryButton: { backgroundColor: colors.surface, borderColor: colors.separator },
  secondaryButtonText: { color: colors.ink },
  destructiveButton: { borderColor: colors.danger },
  destructiveButtonText: { color: colors.danger },
  disabledButton: { opacity: 0.45 },
  pressedButton: { opacity: 0.70 },
  privacyNote: { alignItems: 'flex-start', flexDirection: 'row', marginTop: 18, paddingHorizontal: 8 },
  privacyDot: { backgroundColor: colors.success, borderRadius: 4, height: 7, marginRight: 9, marginTop: 5, width: 7 },
  privacyText: { color: colors.muted, flex: 1, fontSize: 12, fontWeight: '400', lineHeight: 17 },
  scannerScreen: { backgroundColor: '#000000', flex: 1, justifyContent: 'flex-end' },
  scannerHeader: { alignItems: 'center', flexDirection: 'row', left: 24, position: 'absolute', top: 22 },
  scannerBrandMark: { alignItems: 'center', backgroundColor: colors.surface, borderRadius: 10, height: 40, justifyContent: 'center', width: 40 },
  scannerBrand: { color: '#ffffff', fontSize: 16, fontWeight: '600', marginLeft: 10 },
  scanFrame: { alignSelf: 'center', borderColor: colors.surface, borderRadius: 22, borderWidth: 3, height: 246, position: 'absolute', top: '22%', width: 246 },
  scannerFooter: { backgroundColor: 'rgba(0,0,0,0.84)', gap: 13, paddingBottom: 26, paddingHorizontal: 20, paddingTop: 20 },
  scannerEyebrow: { color: '#ffffff', fontSize: 10, fontWeight: '700', letterSpacing: 1.4, textAlign: 'center' },
  scannerInstruction: { color: '#ffffff', fontSize: 17, fontWeight: '600', lineHeight: 23, textAlign: 'center' },
  permissionPanel: { alignItems: 'center', backgroundColor: colors.background, flex: 1, justifyContent: 'center', padding: 30 },
  permissionTitle: { color: colors.ink, fontSize: 26, fontWeight: '700', letterSpacing: -0.6, textAlign: 'center' },
  permissionText: { color: colors.muted, fontSize: 15, fontWeight: '400', lineHeight: 22, marginBottom: 24, marginTop: 10, textAlign: 'center' },
});

export default Sentry.wrap(App);
