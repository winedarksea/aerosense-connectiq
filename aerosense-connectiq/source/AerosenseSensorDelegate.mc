import Toybox.Application.Storage;
import Toybox.BluetoothLowEnergy;
import Toybox.Lang;
import Toybox.Sensor;

//! 5.1 wireless-pairing entry point. The system calls into this delegate from
//! the head unit's native sensor-pairing flow to ask us to scan, pair, and
//! unpair an Aerosense device.
class AerosenseSensorDelegate extends Sensor.SensorDelegate {
    private var _pendingSensor as Sensor.SensorInfo?;
    private var _pendingScanResult as BluetoothLowEnergy.ScanResult?;

    public function initialize() {
        SensorDelegate.initialize();
        var app = getApp();
        var ble = app.getBleDelegate();
        if (ble != null) {
            ble.setScanListener(self);
            ble.setConnectionListener(self);
        }
    }

    public function pairingRequired() as Boolean {
        return true;
    }

    public function onScan() as Boolean {
        if (Storage.getValue(Constants.Keys.PAIRED_SENSOR) != null) {
            return false;
        }
        getApp().getBleDelegate().startScan();
        return true;
    }

    //! Invoked by AerosenseBleDelegate when an advertising Aerosense is seen.
    public function onScanResult(result as BluetoothLowEnergy.ScanResult) as Void {
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

        Sensor.notifyNewSensor(info, true);
        Sensor.notifyScanComplete();

        var ble = getApp().getBleDelegate();
        if (ble != null) {
            ble.stopScan();
        }
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

    //! BleDelegate callback hook: connection up. Persist the paired sensor,
    //! tell the system pairing is complete, and push any stored mass.
    public function procConnection(device as BluetoothLowEnergy.Device) as Void {
        if (_pendingSensor != null && _pendingScanResult != null) {
            Storage.setValue(Constants.Keys.PAIRED_SENSOR, _pendingScanResult);
            Sensor.notifyPairComplete(_pendingSensor);
            _pendingSensor = null;
            _pendingScanResult = null;
        }
        var ble = getApp().getBleDelegate();
        var mass = Storage.getValue(Constants.Keys.MASS_KG);
        if (ble != null && mass != null) {
            ble.writeMassKg(mass as Number);
        }
    }
}
