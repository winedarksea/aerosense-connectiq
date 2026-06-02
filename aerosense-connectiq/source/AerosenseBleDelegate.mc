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
            System.println("Aerosense BLE pairDevice failed: " + e.getErrorMessage());
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
                Storage.setValue(Constants.Keys.PAIRED_SENSOR,
                    _pendingPairResult as BluetoothLowEnergy.ScanResult);
            }
            _enableTelemetryNotifications();
            _notifyConnected(device);
        } else {
            _resetConnection();
            _notifyConnectionFailed("Disconnected");
        }
        WatchUi.requestUpdate();
    }

    private function _enableTelemetryNotifications() as Void {
        if (_telemetryChar == null) {
            return;
        }
        var cccd = _telemetryChar.getDescriptor(BluetoothLowEnergy.cccdUuid());
        if (cccd != null) {
            try {
                cccd.requestWrite([0x01, 0x00]b);
                // A GATT op is now outstanding; hold off any settings writes until
                // onDescriptorWrite fires, since CIQ allows only one op at a time.
                _cccdWriteInFlight = true;
            } catch (e) {
                System.println("Aerosense CCCD write failed: " + e.getErrorMessage());
            }
        }
    }

    private function _resetConnection() as Void {
        _device = null;
        _service = null;
        _telemetryChar = null;
        _speedChar = null;
        _settingsChar = null;
        _pendingPairResult = null;
        _settingsWriteInFlight = false;
        _cccdWriteInFlight = false;
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
            if (_model.parse(value)) {
                WatchUi.requestUpdate();
            }
        }
    }

    public function onCharacteristicWrite(char as BluetoothLowEnergy.Characteristic,
                                          status as BluetoothLowEnergy.Status) as Void {
        if (!char.getUuid().equals(_profileManager.SETTINGS_CHARACTERISTIC) || !_settingsWriteInFlight) {
            return;
        }

        _settingsWriteInFlight = false;
        _flushPendingSettings();
    }

    public function onDescriptorWrite(descriptor as BluetoothLowEnergy.Descriptor,
                                      status as BluetoothLowEnergy.Status) as Void {
        if (BluetoothLowEnergy.cccdUuid().equals(descriptor.getUuid())) {
            // Clear the gate regardless of status so a failed CCCD write can't
            // wedge the settings queue forever; settings sync is independent.
            _cccdWriteInFlight = false;
            _flushPendingSettings();
        }
    }

    //! Write speed_mps as little-endian uint16 cm/s to characteristic 53f3c0b4.
    public function writeSpeedMps(speedMps as Float) as Boolean {
        if (_speedChar == null) {
            return false;
        }
        var cms = (speedMps * 100.0 + 0.5).toNumber();
        if (cms < 0) { cms = 0; }
        if (cms > 65535) { cms = 65535; }
        var bytes = new[2]b;
        bytes.encodeNumber(cms, Lang.NUMBER_FORMAT_UINT16,
            {:offset => 0, :endianness => Lang.ENDIAN_LITTLE});
        _speedChar.requestWrite(bytes,
            {:writeType => BluetoothLowEnergy.WRITE_TYPE_WITH_RESPONSE});
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
        // Wait until the CCCD write completes: only one GATT op may be in flight.
        if (_settingsChar == null || _settingsWriteInFlight || _cccdWriteInFlight ||
                _settingsQueue.size() == 0) {
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
