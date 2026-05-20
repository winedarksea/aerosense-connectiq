import Toybox.Application;
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

    private var _scanListener as WeakReference?;
    private var _connectionListener as WeakReference?;
    private var _scanning as Boolean = false;
    private var _pendingMassKg as Number?;
    private var _pendingWheelCircMm as Number?;
    private var _settingsWriteInFlight as Number?;

    public function initialize(profileManager as ProfileManager, model as TelemetryModel) {
        BleDelegate.initialize();
        _profileManager = profileManager;
        _model = model;
    }

    // -- Scanning -----------------------------------------------------------

    public function setScanListener(listener as Object) as Void {
        _scanListener = listener.weak();
    }

    public function setConnectionListener(listener as Object) as Void {
        _connectionListener = listener.weak();
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
            if (!_advertisesAerosense(result)) {
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
        return false;
    }

    // -- Connection ---------------------------------------------------------

    public function connectTo(scanResult as BluetoothLowEnergy.ScanResult) as Void {
        stopScan();
        BluetoothLowEnergy.pairDevice(scanResult);
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
            _device = device;
            _service = device.getService(_profileManager.AEROSENSE_SERVICE);
            if (_service != null) {
                _telemetryChar = _service.getCharacteristic(_profileManager.TELEMETRY_CHARACTERISTIC);
                _speedChar = _service.getCharacteristic(_profileManager.SPEED_CHARACTERISTIC);
                _settingsChar = _service.getCharacteristic(_profileManager.SETTINGS_CHARACTERISTIC);
                _enableTelemetryNotifications();
                _notifyConnected(device);
            }
        } else {
            _resetConnection();
        }
        WatchUi.requestUpdate();
    }

    private function _enableTelemetryNotifications() as Void {
        if (_telemetryChar == null) {
            return;
        }
        var cccd = _telemetryChar.getDescriptor(BluetoothLowEnergy.cccdUuid());
        if (cccd != null) {
            cccd.requestWrite([0x01, 0x00]b);
        }
    }

    private function _resetConnection() as Void {
        _device = null;
        _service = null;
        _telemetryChar = null;
        _speedChar = null;
        _settingsChar = null;
        _settingsWriteInFlight = null;
    }

    private function _notifyConnected(device as BluetoothLowEnergy.Device) as Void {
        if (_connectionListener != null && _connectionListener.stillAlive()) {
            var listener = _connectionListener.get();
            if (listener != null && (listener has :procConnection)) {
                listener.procConnection(device);
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
        if (!char.getUuid().equals(_profileManager.SETTINGS_CHARACTERISTIC) || _settingsWriteInFlight == null) {
            return;
        }

        if (status != BluetoothLowEnergy.STATUS_SUCCESS) {
            _settingsWriteInFlight = null;
            return;
        }

        if (_settingsWriteInFlight == Constants.SETTINGS_TYPE_MASS_KG_X10) {
            _pendingMassKg = null;
        } else if (_settingsWriteInFlight == Constants.SETTINGS_TYPE_WHEEL_CIRC_MM) {
            _pendingWheelCircMm = null;
        }

        _settingsWriteInFlight = null;
        _flushPendingSettings();
    }

    public function onDescriptorWrite(descriptor as BluetoothLowEnergy.Descriptor,
                                      status as BluetoothLowEnergy.Status) as Void {
        if (status != BluetoothLowEnergy.STATUS_SUCCESS) {
            return;
        }
        if (BluetoothLowEnergy.cccdUuid().equals(descriptor.getUuid())) {
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

    //! Request a coast-down capture. Firmware enforces preconditions (no pedal
    //! power, decelerating, no capture in flight) — this is a request, not a
    //! command.
    public function writeCoastDownTrigger() as Boolean {
        return _writeRequestTlv(Constants.SETTINGS_TYPE_COAST_DOWN_REQUEST);
    }

    //! Request a static pressure calibration. Firmware enforces stationary +
    //! settled-pressure preconditions.
    public function writePressureCalTrigger() as Boolean {
        return _writeRequestTlv(Constants.SETTINGS_TYPE_PRESSURE_CAL_REQUEST);
    }

    private function _writeRequestTlv(typeByte as Number) as Boolean {
        if (_settingsChar == null) {
            return false;
        }
        var tlv = new[3]b;
        tlv[0] = typeByte;
        tlv[1] = 0x01;
        tlv[2] = 0x01;
        _settingsChar.requestWrite(tlv,
            {:writeType => BluetoothLowEnergy.WRITE_TYPE_WITH_RESPONSE});
        return true;
    }

    //! Write the rider+bike+gear mass to the Settings characteristic as TLV
    //! { type=0x01, len=2, value=uint16 LE kg*10 }.
    public function writeMassKg(kg as Number) as Boolean {
        if (kg <= 0) {
            return false;
        }
        _pendingMassKg = kg;
        _flushPendingSettings();
        return true;
    }

    //! Write wheel circumference in millimeters to the Settings characteristic
    //! as TLV { type=0x02, len=2, value=uint16 LE }.
    public function writeWheelCircMm(mm as Number) as Boolean {
        if (mm <= 0) {
            return false;
        }
        _pendingWheelCircMm = mm;
        _flushPendingSettings();
        return true;
    }

    private function _flushPendingSettings() as Void {
        if (_settingsChar == null || _settingsWriteInFlight != null) {
            return;
        }

        if (_pendingMassKg != null) {
            _settingsWriteInFlight = Constants.SETTINGS_TYPE_MASS_KG_X10;
            _settingsChar.requestWrite(_buildMassTlv(_pendingMassKg),
                {:writeType => BluetoothLowEnergy.WRITE_TYPE_WITH_RESPONSE});
            return;
        }

        if (_pendingWheelCircMm != null) {
            _settingsWriteInFlight = Constants.SETTINGS_TYPE_WHEEL_CIRC_MM;
            _settingsChar.requestWrite(_buildWheelCircTlv(_pendingWheelCircMm),
                {:writeType => BluetoothLowEnergy.WRITE_TYPE_WITH_RESPONSE});
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

    private function _buildWheelCircTlv(mm as Number) as ByteArray {
        var circMm = mm.toNumber();
        if (circMm < 1000) { circMm = 1000; }
        if (circMm > 3000) { circMm = 3000; }
        var tlv = new[4]b;
        tlv[0] = Constants.SETTINGS_TYPE_WHEEL_CIRC_MM;
        tlv[1] = 0x02;
        tlv.encodeNumber(circMm, Lang.NUMBER_FORMAT_UINT16,
            {:offset => 2, :endianness => Lang.ENDIAN_LITTLE});
        return tlv;
    }
}
