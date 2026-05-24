import Toybox.Application.Storage;
import Toybox.BluetoothLowEnergy;
import Toybox.Lang;
import Toybox.Sensor;

//! Native Connect IQ sensor pairing for the Aerosense custom BLE peripheral.
//! This delegate must be self-contained: in the system pairing UI, the data
//! field's normal onStart()/view lifecycle may not have created its BLE objects.
class AerosenseSensorDelegate extends Sensor.SensorDelegate {
    private var _profileManager as ProfileManager;
    private var _bleDelegate as AerosenseBleDelegate;
    private var _pendingSensor as Sensor.SensorInfo?;
    private var _reportedScanResult as BluetoothLowEnergy.ScanResult?;

    public function initialize() {
        SensorDelegate.initialize();
        _profileManager = new ProfileManager();
        _bleDelegate = new AerosenseBleDelegate(_profileManager, new TelemetryModel());
        _bleDelegate.setScanListener(self);
        _bleDelegate.setConnectionListener(self);
        BluetoothLowEnergy.setDelegate(_bleDelegate);
        _profileManager.registerProfiles();
    }

    public function pairingRequired() as Boolean {
        return Storage.getValue(Constants.Keys.PAIRED_SENSOR) == null;
    }

    public function onScan() as Boolean {
        if (Storage.getValue(Constants.Keys.PAIRED_SENSOR) != null) {
            return false;
        }

        _reportedScanResult = null;
        _bleDelegate.setScanListener(self);
        _bleDelegate.startScan();
        return true;
    }

    public function onScanResult(result as BluetoothLowEnergy.ScanResult) as Void {
        if (_reportedScanResult != null) {
            return;
        }

        _reportedScanResult = result;
        Sensor.notifyNewSensor(_toSensorInfo(result), false);
        Sensor.notifyScanComplete();
        _bleDelegate.stopScan();
        _bleDelegate.setScanListener(null);
    }

    public function onPair(sensor as Sensor.SensorInfo) as Boolean {
        var data = sensor.data;
        if (data == null) {
            return false;
        }

        var scanResult = data[:bleScanResult] as BluetoothLowEnergy.ScanResult?;
        if (scanResult == null) {
            return false;
        }

        _pendingSensor = sensor;
        return _bleDelegate.connectTo(scanResult);
    }

    public function procConnection(device as BluetoothLowEnergy.Device) as Void {
        if (_pendingSensor != null) {
            Sensor.notifyPairComplete(_pendingSensor as Sensor.SensorInfo);
            _pendingSensor = null;
        }
    }

    public function onUnpair(sensor as Sensor.SensorInfo) as Boolean {
        var data = sensor.data;
        if (data == null) {
            return false;
        }

        var scanResult = data[:bleScanResult] as BluetoothLowEnergy.ScanResult?;
        var paired = Storage.getValue(Constants.Keys.PAIRED_SENSOR) as BluetoothLowEnergy.ScanResult?;
        if (scanResult != null && paired != null && paired.isSameDevice(scanResult)) {
            Storage.deleteValue(Constants.Keys.PAIRED_SENSOR);
            Sensor.notifyUnpairComplete(sensor);
            return true;
        }

        return false;
    }

    private function _toSensorInfo(result as BluetoothLowEnergy.ScanResult) as Sensor.SensorInfo {
        var name = result.getDeviceName();
        if (name == null) {
            name = Constants.DEFAULT_DEVICE_NAME;
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
