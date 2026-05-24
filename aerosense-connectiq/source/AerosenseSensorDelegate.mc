import Toybox.Application.Storage;
import Toybox.BluetoothLowEnergy;
import Toybox.Lang;
import Toybox.Sensor;
import Toybox.Timer;

//! 5.1 wireless-pairing entry point. The system calls into this delegate from
//! the head unit's native sensor-pairing flow to ask us to scan, pair, and
//! unpair an Aerosense device.
class AerosenseSensorDelegate extends Sensor.SensorDelegate {
    private const SCAN_WINDOW_MS = 4000;

    private var _pendingSensor as Sensor.SensorInfo?;
    private var _pendingScanResult as BluetoothLowEnergy.ScanResult?;
    private var _reportedScanResults as Array = [];
    private var _scanActive as Boolean = false;
    private var _scanTimer as Timer.Timer;

    public function initialize() {
        SensorDelegate.initialize();
        _scanTimer = new Timer.Timer();
        // BLE delegate is not set up yet when getSensorDelegate() is called
        // (before onStart). Listeners are wired in onScan() / _completeScan().
    }

    public function pairingRequired() as Boolean {
        return Storage.getValue(Constants.Keys.PAIRED_SENSOR) == null;
    }

    public function onScan() as Boolean {
        if (Storage.getValue(Constants.Keys.PAIRED_SENSOR) != null) {
            Sensor.notifyError("Aerosense is already paired");
            return false;
        }

        var ble = getApp().getBleDelegate();
        if (ble == null) {
            Sensor.notifyError("BLE is unavailable");
            return false;
        }

        ble.setScanListener(self);
        _reportedScanResults = [];
        _scanActive = true;
        _scanTimer.start(method(:_onScanTimeout), SCAN_WINDOW_MS, false);
        ble.startScan();
        return true;
    }

    //! Invoked by AerosenseBleDelegate when an advertising Aerosense is seen.
    public function onScanResult(result as BluetoothLowEnergy.ScanResult) as Void {
        if (!_scanActive || _alreadyReported(result)) {
            return;
        }

        _reportedScanResults.add(result);
        Sensor.notifyNewSensor(_toSensorInfo(result), true);
    }

    public function onPair(sensor as Sensor.SensorInfo) as Boolean {
        _completeScan();

        var data = sensor.data;
        if (data == null) {
            return false;
        }
        var scanResult = data[:bleScanResult] as BluetoothLowEnergy.ScanResult?;
        if (scanResult == null) {
            return false;
        }
        if (BluetoothLowEnergy.pairDevice(scanResult) == null) {
            return false;
        }
        _pendingSensor = sensor;
        _pendingScanResult = scanResult;
        return true;
    }

    public function onUnpair(sensor as Sensor.SensorInfo) as Boolean {
        var data = sensor.data;
        if (data == null) {
            return false;
        }
        var scanResult = data[:bleScanResult] as BluetoothLowEnergy.ScanResult?;
        if (scanResult == null) {
            return false;
        }
        var paired = Storage.getValue(Constants.Keys.PAIRED_SENSOR) as BluetoothLowEnergy.ScanResult?;
        if (paired != null && paired.isSameDevice(scanResult)) {
            Storage.deleteValue(Constants.Keys.PAIRED_SENSOR);
            var ble = getApp().getBleDelegate();
            if (ble != null) {
                ble.disconnect();
            }
            Sensor.notifyUnpairComplete(sensor);
            return true;
        }
        return false;
    }

    //! Called by AerosenseApp.procConnection() after a BLE connection is
    //! established. If a native-pairing flow was in progress, tells the Garmin
    //! system the pairing completed and persists the paired state.
    public function completePairingIfPending() as Void {
        if (_pendingSensor != null) {
            Storage.setValue(Constants.Keys.PAIRED_SENSOR, true);
            Sensor.notifyPairComplete(_pendingSensor as Sensor.SensorInfo);
            _pendingSensor = null;
            _pendingScanResult = null;
        }
    }

    private function _onScanTimeout() as Void {
        _completeScan();
    }

    private function _completeScan() as Void {
        if (!_scanActive) {
            return;
        }

        _scanActive = false;
        _scanTimer.stop();

        var ble = getApp().getBleDelegate();
        if (ble != null) {
            ble.setScanListener(null);
            ble.stopScan();
        }

        Sensor.notifyScanComplete();
    }

    private function _alreadyReported(result as BluetoothLowEnergy.ScanResult) as Boolean {
        for (var i = 0; i < _reportedScanResults.size(); i++) {
            var existing = _reportedScanResults[i] as BluetoothLowEnergy.ScanResult;
            if (existing.isSameDevice(result)) {
                return true;
            }
        }
        return false;
    }

    private function _toSensorInfo(result as BluetoothLowEnergy.ScanResult) as Sensor.SensorInfo {
        var name = result.getDeviceName();
        if (name == null) {
            name = "Aerosense";
        }

        var info = new Sensor.SensorInfo();
        info.name = name;
        info.technology = Sensor.SENSOR_TECHNOLOGY_BLE;
        info.type = Sensor.SENSOR_GENERIC;
        info.data = {:bleScanResult => result};
        info.partNumber = 0;
        info.manufacturerId = 0;
        return info;
    }
}
