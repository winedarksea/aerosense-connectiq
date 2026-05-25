import Toybox.Application.Storage;
import Toybox.BluetoothLowEnergy;
import Toybox.Lang;
import Toybox.Sensor;
import Toybox.System;
import Toybox.Timer;

//! Native Connect IQ sensor pairing for the Aerosense custom BLE peripheral.
//! This delegate must be self-contained: in the system pairing UI, the data
//! field's normal onStart()/view lifecycle may not have created its BLE objects.
class AerosenseSensorDelegate extends Sensor.SensorDelegate {
    private const SCAN_TIMEOUT_MS = 10000;
    private const PAIR_TIMEOUT_MS = 15000;
    private const UUID_AD_TYPE_INCOMPLETE_128 = 0x06;
    private const UUID_AD_TYPE_COMPLETE_128 = 0x07;
    private const NAME_AD_TYPE_SHORT = 0x08;
    private const NAME_AD_TYPE_COMPLETE = 0x09;

    private var _profileManager as ProfileManager;
    private var _bleDelegate as AerosenseBleDelegate;
    private var _pendingSensor as Sensor.SensorInfo?;
    private var _pendingScanResult as BluetoothLowEnergy.ScanResult?;
    private var _reportedScanResults as Array<BluetoothLowEnergy.ScanResult>;
    private var _scanTimer as Timer.Timer?;
    private var _pairTimer as Timer.Timer?;
    private var _scanActive as Boolean = false;
    private var _pairingActive as Boolean = false;
    private var _profileReady as Boolean = false;

    public function initialize() {
        SensorDelegate.initialize();
        _profileManager = new ProfileManager();
        _bleDelegate = new AerosenseBleDelegate(_profileManager, new TelemetryModel());
        _reportedScanResults = [];
        _scanTimer = new Timer.Timer();
        _pairTimer = new Timer.Timer();
        _bleDelegate.setScanFilterEnabled(false);
        _bleDelegate.setScanListener(self);
        _bleDelegate.setConnectionListener(self);
        BluetoothLowEnergy.setDelegate(_bleDelegate);
        _profileReady = _profileManager.registerProfiles();
        System.println("AerosenseSensorDelegate initialized");
    }

    public function pairingRequired() as Boolean {
        System.println("AerosenseSensorDelegate pairingRequired");
        return !_hasStoredPairing();
    }

    public function onScan() as Boolean {
        System.println("AerosenseSensorDelegate onScan");
        if (!_profileReady) {
            Sensor.notifyError("Aerosense BLE profile registration failed");
            return false;
        }
        if (_hasStoredPairing()) {
            return false;
        }

        BluetoothLowEnergy.setDelegate(_bleDelegate);
        _reportedScanResults = [];
        _scanActive = true;
        _bleDelegate.setScanListener(self);
        _bleDelegate.setConnectionListener(self);
        _bleDelegate.startScan();
        if (_scanTimer != null) {
            (_scanTimer as Timer.Timer).start(method(:finishScan), SCAN_TIMEOUT_MS, false);
        }
        return true;
    }

    public function onScanResult(result as BluetoothLowEnergy.ScanResult) as Void {
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
    }

    public function finishScan() as Void {
        if (!_scanActive) {
            return;
        }
        _scanActive = false;
        _bleDelegate.stopScan();
        _bleDelegate.setScanListener(null);
        if (_scanTimer != null) {
            (_scanTimer as Timer.Timer).stop();
        }
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
            if (_pairTimer != null) {
                (_pairTimer as Timer.Timer).start(method(:pairTimeout), PAIR_TIMEOUT_MS,
                    false);
            }
            return true;
        }

        _failPairing("Aerosense BLE pairing failed");
        return false;
    }

    public function procConnection(device as BluetoothLowEnergy.Device) as Void {
        System.println("AerosenseSensorDelegate procConnection");
        if (_pairingActive && _pendingSensor != null) {
            if (_pairTimer != null) {
                (_pairTimer as Timer.Timer).stop();
            }
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

    public function pairTimeout() as Void {
        if (_pairingActive) {
            _bleDelegate.setConnectionListener(null);
            _bleDelegate.disconnect();
            _bleDelegate.setConnectionListener(self);
            _failPairing("Aerosense BLE pairing timed out");
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
        if (_scanTimer != null) {
            (_scanTimer as Timer.Timer).stop();
        }
        if (_pairTimer != null) {
            (_pairTimer as Timer.Timer).stop();
        }
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
        if (_pairTimer != null) {
            (_pairTimer as Timer.Timer).stop();
        }
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
        if ((end - start + 1) < 9) {
            return false;
        }

        return raw[start] == 0x41 &&
               raw[start + 1] == 0x65 &&
               raw[start + 2] == 0x72 &&
               raw[start + 3] == 0x6f &&
               raw[start + 4] == 0x73 &&
               raw[start + 5] == 0x65 &&
               raw[start + 6] == 0x6e &&
               raw[start + 7] == 0x73 &&
               raw[start + 8] == 0x65;
    }
}
