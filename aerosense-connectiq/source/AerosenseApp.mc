import Toybox.Application;
import Toybox.Application.Storage;
import Toybox.BluetoothLowEnergy;
import Toybox.Lang;
import Toybox.Sensor;
import Toybox.Timer;
import Toybox.WatchUi;

class AerosenseApp extends Application.AppBase {
    private var _profileManager as ProfileManager?;
    private var _bleDelegate as AerosenseBleDelegate?;
    private var _model as TelemetryModel?;
    private var _field as WeakReference?;
    private var _autoScanTimer as Timer.Timer?;
    private var _autoScanActive as Boolean = false;
    private var _sensorDelegate as AerosenseSensorDelegate?;

    private const AUTO_SCAN_MS = 12000;

    public function initialize() {
        AppBase.initialize();
    }

    public function onStart(state as Dictionary?) as Void {
        _model = new TelemetryModel();
        _profileManager = new ProfileManager();
        _bleDelegate = new AerosenseBleDelegate(_profileManager, _model);

        BluetoothLowEnergy.setDelegate(_bleDelegate);
        _bleDelegate.setConnectionListener(self);
        _profileManager.registerProfiles();

        // If we've paired before, kick off a background scan so the device
        // reconnects automatically without requiring a tap.
        if (Storage.getValue(Constants.Keys.PAIRED_SENSOR) != null) {
            _startAutoScan();
        }
    }

    private function _startAutoScan() as Void {
        if (_bleDelegate == null || _autoScanActive) {
            return;
        }
        _autoScanActive = true;
        (_bleDelegate as AerosenseBleDelegate).setScanListener(self);
        (_bleDelegate as AerosenseBleDelegate).startScan();
        _autoScanTimer = new Timer.Timer();
        (_autoScanTimer as Timer.Timer).start(method(:_onAutoScanTimeout), AUTO_SCAN_MS, false);
    }

    public function _onAutoScanTimeout() as Void {
        _stopAutoScan();
    }

    //! Called by AerosenseField when it takes over the scan listener so the
    //! auto-scan timer doesn't fire later and cancel the manual scan.
    public function cancelAutoScan() as Void {
        if (!_autoScanActive) {
            return;
        }
        _autoScanActive = false;
        if (_autoScanTimer != null) {
            (_autoScanTimer as Timer.Timer).stop();
            _autoScanTimer = null;
        }
        // Do NOT stop the BLE scan here — the field is now managing it.
    }

    private function _stopAutoScan() as Void {
        _autoScanActive = false;
        if (_autoScanTimer != null) {
            (_autoScanTimer as Timer.Timer).stop();
            _autoScanTimer = null;
        }
        if (_bleDelegate != null) {
            var ble = _bleDelegate as AerosenseBleDelegate;
            ble.setScanListener(null);
            ble.stopScan();
        }
    }

    public function onScanResult(result as BluetoothLowEnergy.ScanResult) as Void {
        _stopAutoScan();
        if (_bleDelegate != null) {
            (_bleDelegate as AerosenseBleDelegate).connectTo(result);
        }
    }

    public function onStop(state as Dictionary?) as Void {
        _stopAutoScan();
        if (_bleDelegate != null) {
            _bleDelegate.setScanListener(null);
            _bleDelegate.stopScan();
        }
        _bleDelegate = null;
        _profileManager = null;
        _model = null;
    }

    public function getModel() as TelemetryModel {
        return _model;
    }

    public function getBleDelegate() as AerosenseBleDelegate? {
        return _bleDelegate;
    }

    public function getProfileManager() as ProfileManager {
        return _profileManager;
    }

    public function getInitialView() as [WatchUi.Views] or [WatchUi.Views, WatchUi.InputDelegates] {
        var field = new AerosenseField(_model);
        _field = field.weak();
        return [field, new AerosenseFieldDelegate(field)];
    }

    //! Forward settings sync to the data field so it can refresh the
    //! tap-to-coast toggle without waiting for the next tick.
    public function onSettingsChanged() as Void {
        if (_field != null && _field.stillAlive()) {
            var f = _field.get();
            if (f != null && (f has :onSettingsChanged)) {
                f.onSettingsChanged();
            }
        }
    }

    public function procConnection(device as BluetoothLowEnergy.Device) as Void {
        _stopAutoScan();
        if (_sensorDelegate != null) {
            _sensorDelegate.completePairingIfPending();
        }
        var mass = Storage.getValue(Constants.Keys.MASS_KG);
        if (mass != null && _bleDelegate != null) {
            (_bleDelegate as AerosenseBleDelegate).queueMassKg(mass as Number);
        }
    }

    //! Settings for the custom data field. Device linking is handled by the
    //! field's custom BLE scan flow, not Garmin's native sensor pairing UI.
    public function getSensorConfigurationView(sensor as Sensor.SensorInfo)
            as [WatchUi.Views] or [WatchUi.Views, WatchUi.InputDelegates] {
        var view = new SensorConfigurationView();
        return [view, new SensorConfigurationDelegate(view)];
    }

    public function getSensorDelegate() as Sensor.SensorDelegate or Null {
        if (_sensorDelegate == null) {
            _sensorDelegate = new AerosenseSensorDelegate();
        }
        return _sensorDelegate;
    }
}

function getApp() as AerosenseApp {
    return Application.getApp() as AerosenseApp;
}
