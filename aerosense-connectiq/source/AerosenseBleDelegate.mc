import Toybox.Application;
import Toybox.Application.Storage;
import Toybox.BluetoothLowEnergy;
import Toybox.Lang;
import Toybox.System;
import Toybox.WatchUi;

//! Owns the BLE connection lifecycle and bridges notify/write events to the app.
class AerosenseBleDelegate extends BluetoothLowEnergy.BleDelegate {
    private var _profileManager as ProfileManager;
    private var _model as TelemetryModel;

    private var _device as BluetoothLowEnergy.Device?;
    private var _service as BluetoothLowEnergy.Service?;
    private var _telemetryChar as BluetoothLowEnergy.Characteristic?;
    private var _speedChar as BluetoothLowEnergy.Characteristic?;
    private var _settingsChar as BluetoothLowEnergy.Characteristic?;
    private var _pendingPairResult as BluetoothLowEnergy.ScanResult?;

    private var _scanListener as WeakReference?;
    private var _connectionListener as WeakReference?;
    private var _scanning as Boolean = false;
    private var _scanFilterEnabled as Boolean = true;
    private var _settingsQueue as Array<ByteArray> = [];
    private var _settingsWriteInFlight as Boolean = false;
    private var _cccdWriteInFlight as Boolean = false;
    private var _speedWriteInFlight as Boolean = false;
    // Wall-clock stamp of the in-flight speed write so a lost response can't
    // wedge the gate forever; see writeSpeedMps / _speedWriteStale.
    private var _speedWriteStartedMs as Number = 0;
    private const SPEED_WRITE_TIMEOUT_MS = 3000;

    // -- Diagnostics (surfaced by the on-screen debug HUD) ------------------
    // These let us tell, without System.println on the head unit, whether the
    // CCCD subscription was issued/accepted and whether telemetry notifications
    // are actually arriving and parsing. See the on-screen HUD in AerosenseField.
    private var _dbgCccdFound as Boolean = false;
    private var _dbgLastDescWriteStatus as Number? = null;
    private var _dbgNotifyCount as Number = 0;
    private var _dbgLastParseOk as Boolean = false;
    private var _dbgLastValueLen as Number = 0;

    public function initialize(profileManager as ProfileManager, model as TelemetryModel) {
        BleDelegate.initialize();
        _profileManager = profileManager;
        _model = model;
    }

    // -- Scanning -----------------------------------------------------------

    public function setScanListener(listener as Object?) as Void {
        _scanListener = (listener == null) ? null : listener.weak();
    }

    public function setConnectionListener(listener as Object?) as Void {
        _connectionListener = (listener == null) ? null : listener.weak();
    }

    public function setScanFilterEnabled(enabled as Boolean) as Void {
        _scanFilterEnabled = enabled;
    }

    public function startScan() as Void {
        if (!_scanning) {
            BluetoothLowEnergy.setScanState(BluetoothLowEnergy.SCAN_STATE_SCANNING);
            _scanning = true;
        }
    }

    public function stopScan() as Void {
        if (_scanning) {
            BluetoothLowEnergy.setScanState(BluetoothLowEnergy.SCAN_STATE_OFF);
            _scanning = false;
        }
    }

    public function onScanResults(scanResults as Iterator) as Void {
        for (var result = scanResults.next(); result != null; result = scanResults.next()) {
            if (!(result instanceof BluetoothLowEnergy.ScanResult)) {
                continue;
            }
            if (_scanFilterEnabled && !_advertisesAerosense(result)) {
                continue;
            }
            if (_scanListener != null && _scanListener.stillAlive()) {
                var l = _scanListener.get();
                if (l != null && (l has :onScanResult)) {
                    l.onScanResult(result);
                }
            }
        }
    }

    private function _advertisesAerosense(result as BluetoothLowEnergy.ScanResult) as Boolean {
        var uuids = result.getServiceUuids();
        for (var u = uuids.next(); u != null; u = uuids.next()) {
            if (u.equals(_profileManager.AEROSENSE_SERVICE)) {
                return true;
            }
        }

        var name = result.getDeviceName();
        return name != null && name.find(Constants.DEFAULT_DEVICE_NAME) == 0;
    }

    // -- Connection ---------------------------------------------------------

    public function connectTo(scanResult as BluetoothLowEnergy.ScanResult) as Boolean {
        stopScan();
        var device = null;
        try {
            device = BluetoothLowEnergy.pairDevice(scanResult);
        } catch (e) {
            var msg = e.getErrorMessage();
            System.println("Aerosense BLE pairDevice: " + msg);
            if (msg != null && msg.equals("pairingRequired")) {
                // pairDevice() throws this when the device requests BLE bonding
                // and the OS has not yet bonded it at the system level, OR when
                // the device is registered as a system sensor.  Either way the
                // OS will manage the connection; wait for onConnectedStateChanged.
                _pendingPairResult = scanResult;
                return true;
            }
            _notifyConnectionFailed("Pairing failed");
            return false;
        }
        if (device != null) {
            _pendingPairResult = scanResult;
            return true;
        }
        _notifyConnectionFailed("Pairing returned no device");
        return false;
    }

    public function disconnect() as Void {
        if (_device != null) {
            BluetoothLowEnergy.unpairDevice(_device);
        }
        _resetConnection();
    }

    public function isConnected() as Boolean {
        return _telemetryChar != null;
    }

    public function onConnectedStateChanged(device as BluetoothLowEnergy.Device,
                                            state as BluetoothLowEnergy.ConnectionState) as Void {
        try {
            if (state == BluetoothLowEnergy.CONNECTION_STATE_CONNECTED) {
                if (_device != null) {
                    return;
                }
                _device = device;
                _service = device.getService(_profileManager.AEROSENSE_SERVICE);
                if (_service == null) {
                    _resetConnection();
                    _notifyConnectionFailed("Aerosense service not found");
                    WatchUi.requestUpdate();
                    return;
                }

                _telemetryChar = _service.getCharacteristic(_profileManager.TELEMETRY_CHARACTERISTIC);
                _speedChar = _service.getCharacteristic(_profileManager.SPEED_CHARACTERISTIC);
                _settingsChar = _service.getCharacteristic(_profileManager.SETTINGS_CHARACTERISTIC);
                if (_telemetryChar == null || _speedChar == null || _settingsChar == null) {
                    _resetConnection();
                    _notifyConnectionFailed("Aerosense characteristics not found");
                    WatchUi.requestUpdate();
                    return;
                }
                if (_pendingPairResult != null) {
                    _storePairedSensor(_pendingPairResult as BluetoothLowEnergy.ScanResult);
                }
                _enableTelemetryNotifications();
                _notifyConnected(device);
            } else {
                _resetConnection();
                _notifyConnectionFailed("Disconnected");
            }
        } catch (e) {
            System.println("Aerosense BLE connection handler failed: " +
                e.getErrorMessage());
            _resetConnection();
            _notifyConnectionFailed("Connection setup failed");
        }
        WatchUi.requestUpdate();
    }

    private function _storePairedSensor(scanResult as BluetoothLowEnergy.ScanResult) as Void {
        try {
            Storage.setValue(Constants.Keys.PAIRED_SENSOR, scanResult);
        } catch (e) {
            System.println("Aerosense BLE paired sensor store failed: " +
                e.getErrorMessage());
        }
    }

    private function _enableTelemetryNotifications() as Void {
        if (_telemetryChar == null) {
            return;
        }
        var cccd = _telemetryChar.getDescriptor(BluetoothLowEnergy.cccdUuid());
        _dbgCccdFound = (cccd != null);
        if (cccd != null) {
            try {
                cccd.requestWrite([0x01, 0x00]b);
                // A GATT op is now outstanding; hold off any settings writes until
                // onDescriptorWrite fires, since CIQ allows only one op at a time.
                _cccdWriteInFlight = true;
            } catch (e) {
                System.println("Aerosense CCCD write failed: " + e.getErrorMessage());
            }
        } else {
            // Silent no-op here would leave the field in "Searching..." forever:
            // no descriptor means no subscription means no notifications.
            System.println("Aerosense telemetry CCCD descriptor not found");
        }
    }

    // -- Diagnostics getters (read by the on-screen debug HUD) -------------

    public function dbgCccdFound() as Boolean { return _dbgCccdFound; }
    public function dbgLastDescWriteStatus() as Number? { return _dbgLastDescWriteStatus; }
    public function dbgNotifyCount() as Number { return _dbgNotifyCount; }
    public function dbgLastParseOk() as Boolean { return _dbgLastParseOk; }
    public function dbgLastValueLen() as Number { return _dbgLastValueLen; }

    private function _resetConnection() as Void {
        _device = null;
        _service = null;
        _telemetryChar = null;
        _speedChar = null;
        _settingsChar = null;
        _pendingPairResult = null;
        _settingsWriteInFlight = false;
        _cccdWriteInFlight = false;
        _speedWriteInFlight = false;
        _speedWriteStartedMs = 0;
        _settingsQueue = [];
    }

    private function _notifyConnected(device as BluetoothLowEnergy.Device) as Void {
        if (_connectionListener != null && _connectionListener.stillAlive()) {
            var listener = _connectionListener.get();
            if (listener != null && (listener has :procConnection)) {
                listener.procConnection(device);
            }
        }
    }

    private function _notifyConnectionFailed(reason as String) as Void {
        if (_connectionListener != null && _connectionListener.stillAlive()) {
            var listener = _connectionListener.get();
            if (listener != null && (listener has :procConnectionFailed)) {
                listener.procConnectionFailed(reason);
            }
        }
    }

    // -- Notifications / writes --------------------------------------------

    public function onCharacteristicChanged(char as BluetoothLowEnergy.Characteristic,
                                            value as ByteArray) as Void {
        if (char.getUuid().equals(_profileManager.TELEMETRY_CHARACTERISTIC)) {
            // Count every arrival before parsing so the HUD can distinguish
            // "no notifications" (count stays 0) from "notifications arrive but
            // parse rejects them" (count climbs, lastParseOk false).
            _dbgNotifyCount += 1;
            _dbgLastValueLen = (value == null) ? 0 : value.size();
            var ok = _model.parse(value);
            _dbgLastParseOk = ok;
            if (ok) {
                WatchUi.requestUpdate();
            }
        }
    }

    public function onCharacteristicWrite(char as BluetoothLowEnergy.Characteristic,
                                          status as BluetoothLowEnergy.Status) as Void {
        var uuid = char.getUuid();
        if (uuid.equals(_profileManager.SPEED_CHARACTERISTIC)) {
            // Clear the speed gate so the next tick may issue a fresh write.
            _speedWriteInFlight = false;
            _speedWriteStartedMs = 0;
            return;
        }
        if (!uuid.equals(_profileManager.SETTINGS_CHARACTERISTIC) || !_settingsWriteInFlight) {
            return;
        }

        _settingsWriteInFlight = false;
        _flushPendingSettings();
    }

    public function onDescriptorWrite(descriptor as BluetoothLowEnergy.Descriptor,
                                      status as BluetoothLowEnergy.Status) as Void {
        if (BluetoothLowEnergy.cccdUuid().equals(descriptor.getUuid())) {
            _dbgLastDescWriteStatus = status;
            // Clear the gate regardless of status so a failed CCCD write can't
            // wedge the settings queue forever; settings sync is independent.
            _cccdWriteInFlight = false;
            _flushPendingSettings();
        }
    }

    //! Write speed_mps as little-endian uint16 cm/s to characteristic 53f3c0b4.
    //! Connect IQ permits only one outstanding GATT operation; issuing a write
    //! while another is in flight throws. We therefore drop the sample (speed is
    //! rate-based, freshest wins) rather than queue it, and guard the call so a
    //! throw can't leave the field hung (the crash seen in CIQ_LOG.txt).
    public function writeSpeedMps(speedMps as Float) as Boolean {
        if (_speedChar == null) {
            return false;
        }
        if (_cccdWriteInFlight || _settingsWriteInFlight || _speedWriteBusy()) {
            return false;
        }
        var cms = (speedMps * 100.0 + 0.5).toNumber();
        if (cms < 0) { cms = 0; }
        if (cms > 65535) { cms = 65535; }
        var bytes = new[2]b;
        bytes.encodeNumber(cms, Lang.NUMBER_FORMAT_UINT16,
            {:offset => 0, :endianness => Lang.ENDIAN_LITTLE});
        try {
            _speedChar.requestWrite(bytes,
                {:writeType => BluetoothLowEnergy.WRITE_TYPE_WITH_RESPONSE});
        } catch (e) {
            // A missed speed write is non-fatal: the device falls back to its
            // own speed source and we retry on the next tick. Never let it crash.
            System.println("Aerosense speed write failed: " + e.getErrorMessage());
            _speedWriteInFlight = false;
            _speedWriteStartedMs = 0;
            return false;
        }
        _speedWriteInFlight = true;
        _speedWriteStartedMs = System.getTimer();
        return true;
    }

    //! True while a speed write is outstanding. Self-clears after a timeout so a
    //! dropped onCharacteristicWrite can't wedge speed forever (getTimer wraps;
    //! treat negative deltas as still-in-flight, the next tick re-checks).
    private function _speedWriteBusy() as Boolean {
        if (!_speedWriteInFlight) {
            return false;
        }
        var dt = System.getTimer() - _speedWriteStartedMs;
        if (dt >= SPEED_WRITE_TIMEOUT_MS) {
            _speedWriteInFlight = false;
            _speedWriteStartedMs = 0;
            return false;
        }
        return true;
    }

    //! Request a static pressure calibration. Firmware enforces stationary +
    //! settled-pressure preconditions.
    public function queuePressureCalRequest() as Boolean {
        return _queueSettingsTlv(_buildRequestTlv(Constants.SETTINGS_TYPE_PRESSURE_CAL_REQUEST));
    }

    private function _buildRequestTlv(typeByte as Number) as ByteArray {
        var tlv = new[3]b;
        tlv[0] = typeByte;
        tlv[1] = 0x01;
        tlv[2] = 0x01;
        return tlv;
    }

    //! Write the rider+bike+gear mass to the Settings characteristic as TLV
    //! { type=0x01, len=2, value=uint16 LE kg*10 }.
    public function queueMassKg(kg as Number) as Boolean {
        if (kg <= 0) {
            return false;
        }
        return _queueSettingsTlv(_buildMassTlv(kg));
    }

    private function _queueSettingsTlv(tlv as ByteArray) as Boolean {
        if (_settingsChar == null) {
            return false;
        }

        _settingsQueue.add(tlv);
        _flushPendingSettings();
        return true;
    }

    private function _flushPendingSettings() as Void {
        // Only one GATT op may be in flight: wait out the CCCD write and any
        // outstanding speed write before issuing a queued settings write.
        if (_settingsChar == null || _settingsWriteInFlight || _cccdWriteInFlight ||
                _speedWriteBusy() || _settingsQueue.size() == 0) {
            return;
        }
        var tlv = _settingsQueue[0] as ByteArray;
        _settingsQueue.remove(tlv);
        try {
            _settingsChar.requestWrite(tlv,
                {:writeType => BluetoothLowEnergy.WRITE_TYPE_WITH_RESPONSE});
            _settingsWriteInFlight = true;
        } catch (e) {
            // Drop this TLV rather than crash or spin; a missed settings write is
            // non-fatal and the connection stays up.
            System.println("Aerosense settings write failed: " + e.getErrorMessage());
            _settingsWriteInFlight = false;
        }
    }

    private function _buildMassTlv(kg as Number) as ByteArray {
        var kgX10 = (kg * 10).toNumber();
        if (kgX10 < 200) { kgX10 = 200; }
        if (kgX10 > 2500) { kgX10 = 2500; }
        var tlv = new[4]b;
        tlv[0] = Constants.SETTINGS_TYPE_MASS_KG_X10;
        tlv[1] = 0x02;
        tlv.encodeNumber(kgX10, Lang.NUMBER_FORMAT_UINT16,
            {:offset => 2, :endianness => Lang.ENDIAN_LITTLE});
        return tlv;
    }
}
