import Toybox.Application.Storage;
import Toybox.BluetoothLowEnergy;
import Toybox.Lang;
import Toybox.Sensor;
import Toybox.System;

//! Native Connect IQ sensor pairing for the Aerosense custom BLE peripheral.
//! This delegate must be self-contained: in the system pairing UI, the data
//! field's normal onStart()/view lifecycle may not have created its BLE objects.
//!
//! IMPORTANT: Data Fields cannot import Toybox.Timer (Connect IQ permission
//! restriction — throws "Module 'Toybox.Timer' not available to 'Data Field'"
//! at runtime even though the simulator allows it). Scan and pair timeouts are
//! therefore driven entirely by the head unit's pairing UI, which provides its
//! own countdown and cancel affordance. Do not reintroduce Timer use here.
class AerosenseSensorDelegate extends Sensor.SensorDelegate {
    private const UUID_AD_TYPE_INCOMPLETE_128 = 0x06;
    private const UUID_AD_TYPE_COMPLETE_128 = 0x07;
    private const NAME_AD_TYPE_SHORT = 0x08;
    private const NAME_AD_TYPE_COMPLETE = 0x09;

    private var _profileManager as ProfileManager;
    private var _bleDelegate as AerosenseBleDelegate;
    private var _pendingSensor as Sensor.SensorInfo?;
    private var _pendingScanResult as BluetoothLowEnergy.ScanResult?;
    private var _reportedScanResults as Array<BluetoothLowEnergy.ScanResult>;
    private var _scanActive as Boolean = false;
    private var _pairingActive as Boolean = false;
    private var _profileReady as Boolean = false;

    public function initialize() {
        SensorDelegate.initialize();
        _profileManager = new ProfileManager();
        _bleDelegate = new AerosenseBleDelegate(_profileManager, new TelemetryModel());
        _reportedScanResults = [];
        _bleDelegate.setScanFilterEnabled(false);
        _bleDelegate.setScanListener(self);
        _bleDelegate.setConnectionListener(self);
        BluetoothLowEnergy.setDelegate(_bleDelegate);
        _profileReady = _profileManager.registerProfiles();
        System.println("AerosenseSensorDelegate initialized");
    }

    public function pairingRequired() as Boolean {
        System.println("AerosenseSensorDelegate pairingRequired");
        // Defer the pairing prompt until the field has been placed on a data
        // screen at least once. On first install the system calls this before
        // the user has added the field to any screen, which causes the pairing
        // UI to appear without listing our sensor. Returning false here causes
        // the system to skip the prompt; once the field is viewed (flag set in
        // AerosenseField.initialize) the next check will return true and the
        // pairing UI will find the sensor correctly.
        if (!(Storage.getValue(Constants.Keys.FIELD_VIEWED) as Boolean?)) {
            return false;
        }
        return !_hasStoredPairing();
    }

    public function onScan() as Boolean {
        System.println("AerosenseSensorDelegate onScan");
        if (!_profileReady) {
            Sensor.notifyError("Aerosense BLE profile registration failed");
            return false;
        }
        // Intentionally do NOT bail out when a pairing is already stored: the
        // user may be re-pairing, and a stale stored value must never block a
        // fresh scan (see pairingRequired()).

        try {
            BluetoothLowEnergy.setDelegate(_bleDelegate);
            _reportedScanResults = [];
            _scanActive = true;
            _bleDelegate.setScanListener(self);
            _bleDelegate.setConnectionListener(self);
            _bleDelegate.startScan();
        } catch (e) {
            _scanActive = false;
            System.println("AerosenseSensorDelegate onScan failed: " + e.getErrorMessage());
            Sensor.notifyError("Aerosense BLE scan failed");
            return false;
        }
        // No scan-timeout timer: see class header — Toybox.Timer is unavailable
        // to Data Fields. The system pairing UI cancels the scan itself.
        return true;
    }

    public function onScanResult(result as BluetoothLowEnergy.ScanResult) as Void {
        // Guard the whole body: a single malformed advertisement must never
        // throw out of this system callback and abort the pairing scan.
        try {
            var name = result.getDeviceName();
            System.println("AerosenseSensorDelegate onScanResult " +
                ((name == null) ? "<unnamed>" : name));
            if (!_isAerosenseCandidate(result)) {
                return;
            }
            if (_alreadyReported(result)) {
                return;
            }

            _reportedScanResults.add(result);
            Sensor.notifyNewSensor(_toSensorInfo(result), false);
        } catch (e) {
            System.println("AerosenseSensorDelegate onScanResult error: " +
                e.getErrorMessage());
        }
    }

    public function finishScan() as Void {
        if (!_scanActive) {
            return;
        }
        _scanActive = false;
        _bleDelegate.stopScan();
        _bleDelegate.setScanListener(null);
        Sensor.notifyScanComplete();
    }

    public function onPair(sensor as Sensor.SensorInfo) as Boolean {
        System.println("AerosenseSensorDelegate onPair");
        if (!_profileReady) {
            Sensor.notifyError("Aerosense BLE profile registration failed");
            return false;
        }
        var data = sensor.data;
        if (data == null) {
            Sensor.notifyError("Aerosense sensor missing BLE scan result");
            return false;
        }

        var scanResult = data[:bleScanResult] as BluetoothLowEnergy.ScanResult?;
        if (scanResult == null) {
            Sensor.notifyError("Aerosense sensor missing BLE scan result");
            return false;
        }

        BluetoothLowEnergy.setDelegate(_bleDelegate);
        _pendingSensor = sensor;
        _pendingScanResult = scanResult;
        _pairingActive = true;
        _bleDelegate.setConnectionListener(self);
        finishScan();
        if (_bleDelegate.connectTo(scanResult)) {
            // No pair-timeout timer: see class header. The system pairing UI
            // shows its own timeout and a user-cancel path; failure surfaces
            // via procConnectionFailed.
            return true;
        }

        _failPairing("Aerosense BLE pairing failed");
        return false;
    }

    public function procConnection(device as BluetoothLowEnergy.Device) as Void {
        System.println("AerosenseSensorDelegate procConnection");
        if (_pairingActive && _pendingSensor != null) {
            Sensor.notifyPairComplete(_pendingSensor as Sensor.SensorInfo);
            if (_pendingScanResult != null) {
                Storage.setValue(Constants.Keys.PAIRED_SENSOR,
                    _pendingScanResult as BluetoothLowEnergy.ScanResult);
            }
            _pendingSensor = null;
            _pendingScanResult = null;
            _pairingActive = false;
        }
    }

    public function procConnectionFailed(reason as String) as Void {
        System.println("AerosenseSensorDelegate procConnectionFailed " + reason);
        if (_pairingActive) {
            _failPairing(reason);
        }
    }

    public function onUnpair(sensor as Sensor.SensorInfo) as Boolean {
        System.println("AerosenseSensorDelegate onUnpair");
        var data = sensor.data;
        var scanResult = (data == null) ? null : data[:bleScanResult] as BluetoothLowEnergy.ScanResult?;
        var paired = Storage.getValue(Constants.Keys.PAIRED_SENSOR) as BluetoothLowEnergy.ScanResult?;
        if (scanResult == null || paired == null || paired.isSameDevice(scanResult)) {
            _bleDelegate.disconnect();
            Storage.deleteValue(Constants.Keys.PAIRED_SENSOR);
            Sensor.notifyUnpairComplete(sensor);
            _pendingSensor = null;
            _pendingScanResult = null;
            _pairingActive = false;
            return true;
        }

        return false;
    }

    public function shutdown() as Void {
        _scanActive = false;
        _pairingActive = false;
        _bleDelegate.setScanListener(null);
        _bleDelegate.setConnectionListener(null);
        _bleDelegate.stopScan();
    }

    private function _toSensorInfo(result as BluetoothLowEnergy.ScanResult) as Sensor.SensorInfo {
        var name = result.getDeviceName();
        if (name == null) {
            name = Constants.DEFAULT_DEVICE_NAME;
        }

        var info = new Sensor.SensorInfo();
        info.name = name;
        info.technology = Sensor.SENSOR_TECHNOLOGY_BLE;
        info.enabled = true;
        info.type = Sensor.SENSOR_GENERIC;
        info.data = {:bleScanResult => result};
        info.partNumber = 0;
        info.manufacturerId = 0;
        info.softwareVersion = 0;
        return info;
    }

    private function _alreadyReported(result as BluetoothLowEnergy.ScanResult) as Boolean {
        for (var i = 0; i < _reportedScanResults.size(); i += 1) {
            if ((_reportedScanResults[i] as BluetoothLowEnergy.ScanResult).isSameDevice(result)) {
                return true;
            }
        }
        return false;
    }

    private function _hasStoredPairing() as Boolean {
        return Storage.getValue(Constants.Keys.PAIRED_SENSOR) instanceof
            BluetoothLowEnergy.ScanResult;
    }

    private function _failPairing(reason as String) as Void {
        _pendingSensor = null;
        _pendingScanResult = null;
        _pairingActive = false;
        Sensor.notifyError(reason);
    }

    private function _isAerosenseCandidate(result as BluetoothLowEnergy.ScanResult) as Boolean {
        var uuids = result.getServiceUuids();
        for (var u = uuids.next(); u != null; u = uuids.next()) {
            if (u.equals(_profileManager.AEROSENSE_SERVICE)) {
                System.println("AerosenseSensorDelegate matched service uuid");
                return true;
            }
        }

        var name = result.getDeviceName();
        if (name != null && name.find(Constants.DEFAULT_DEVICE_NAME) == 0) {
            System.println("AerosenseSensorDelegate matched device name");
            return true;
        }

        var raw = result.getRawData();
        if (_rawContainsAerosenseUuid(raw)) {
            System.println("AerosenseSensorDelegate matched raw service uuid");
            return true;
        }
        if (_rawContainsAerosenseName(raw)) {
            System.println("AerosenseSensorDelegate matched raw name");
            return true;
        }

        return false;
    }

    private function _rawContainsAerosenseUuid(raw as ByteArray) as Boolean {
        var i = 0;
        while (i < raw.size()) {
            var len = raw[i];
            if (len == 0 || i + len >= raw.size()) {
                return false;
            }

            var type = raw[i + 1];
            if (type == UUID_AD_TYPE_INCOMPLETE_128 || type == UUID_AD_TYPE_COMPLETE_128) {
                var cursor = i + 2;
                var end = i + 1 + len;
                while (cursor + 15 <= end) {
                    if (_matchesAerosenseUuidBytes(raw, cursor)) {
                        return true;
                    }
                    cursor += 16;
                }
            }
            i += len + 1;
        }
        return false;
    }

    private function _matchesAerosenseUuidBytes(raw as ByteArray, offset as Number) as Boolean {
        // UUID 53f3c0b1-4f7f-4787-8af0-0c9dd053cda0 in BLE little-endian wire order.
        // Zephyr BT_UUID_128_ENCODE emits each component LSB-first, so the full
        // 16-byte sequence in the AD packet is the bitwise reversal of the RFC 4122
        // string representation.
        return raw[offset]      == 0xa0 &&
               raw[offset + 1]  == 0xcd &&
               raw[offset + 2]  == 0x53 &&
               raw[offset + 3]  == 0xd0 &&
               raw[offset + 4]  == 0x9d &&
               raw[offset + 5]  == 0x0c &&
               raw[offset + 6]  == 0xf0 &&
               raw[offset + 7]  == 0x8a &&
               raw[offset + 8]  == 0x87 &&
               raw[offset + 9]  == 0x47 &&
               raw[offset + 10] == 0x7f &&
               raw[offset + 11] == 0x4f &&
               raw[offset + 12] == 0xb1 &&
               raw[offset + 13] == 0xc0 &&
               raw[offset + 14] == 0xf3 &&
               raw[offset + 15] == 0x53;
    }

    private function _rawContainsAerosenseName(raw as ByteArray) as Boolean {
        var i = 0;
        while (i < raw.size()) {
            var len = raw[i];
            if (len == 0 || i + len >= raw.size()) {
                return false;
            }

            var type = raw[i + 1];
            if (type == NAME_AD_TYPE_SHORT || type == NAME_AD_TYPE_COMPLETE) {
                if (_rawNameStartsWithAerosense(raw, i + 2, i + 1 + len)) {
                    return true;
                }
            }
            i += len + 1;
        }
        return false;
    }

    private function _rawNameStartsWithAerosense(raw as ByteArray, start as Number,
                                                end as Number) as Boolean {
        // Matches the firmware's custom-service identity name "Aero Custom"
        // (11 bytes). The "Aero CSC" identity is reserved for Garmin's native
        // CSC consumer and intentionally not matched.
        if ((end - start + 1) < 11) {
            return false;
        }

        return raw[start]      == 0x41 &&
               raw[start + 1]  == 0x65 &&
               raw[start + 2]  == 0x72 &&
               raw[start + 3]  == 0x6f &&
               raw[start + 4]  == 0x20 &&
               raw[start + 5]  == 0x43 &&
               raw[start + 6]  == 0x75 &&
               raw[start + 7]  == 0x73 &&
               raw[start + 8]  == 0x74 &&
               raw[start + 9]  == 0x6f &&
               raw[start + 10] == 0x6d;
    }
}
