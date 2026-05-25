import Toybox.Application;
import Toybox.Application.Storage;
import Toybox.BluetoothLowEnergy;
import Toybox.Lang;
import Toybox.Sensor;
import Toybox.WatchUi;

class AerosenseApp extends Application.AppBase {
    private var _profileManager as ProfileManager?;
    private var _bleDelegate as AerosenseBleDelegate?;
    private var _model as TelemetryModel?;
    private var _field as WeakReference?;
    private var _foregroundConnectStarted as Boolean = false;

    public function initialize() {
        AppBase.initialize();
    }

    public function onStart(state as Dictionary?) as Void {
        _model = new TelemetryModel();
        _profileManager = new ProfileManager();
        _bleDelegate = new AerosenseBleDelegate(_profileManager, _model);
    }

    private function _startForegroundConnection() as Void {
        if (_bleDelegate == null || _foregroundConnectStarted) {
            return;
        }
        _foregroundConnectStarted = true;
        BluetoothLowEnergy.setDelegate(_bleDelegate);
        _bleDelegate.setConnectionListener(self);
        _profileManager.registerProfiles();
        var paired = Storage.getValue(Constants.Keys.PAIRED_SENSOR);
        if (paired instanceof BluetoothLowEnergy.ScanResult) {
            _bleDelegate.connectTo(paired as BluetoothLowEnergy.ScanResult);
        }
    }

    public function onStop(state as Dictionary?) as Void {
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
        _startForegroundConnection();
        var field = new AerosenseField(_model);
        _field = field.weak();
        return [field];
    }

    //! Forward settings sync to the data field and push app settings over BLE
    //! when connected.
    public function onSettingsChanged() as Void {
        _syncMassSetting();
        if (_field != null && _field.stillAlive()) {
            var f = _field.get();
            if (f != null && (f has :onSettingsChanged)) {
                f.onSettingsChanged();
            }
        }
    }

    public function procConnection(device as BluetoothLowEnergy.Device) as Void {
        _syncMassSetting();
    }

    private function _syncMassSetting() as Void {
        if (_bleDelegate == null) {
            return;
        }
        var mass = Application.Properties.getValue(Constants.PROP_MASS_KG);
        (_bleDelegate as AerosenseBleDelegate).queueMassKg(mass as Number);
    }

    //! Native Connect IQ sensor-pairing entry point. This is separate from the
    //! foreground data-field BLE delegate because Garmin may instantiate it in
    //! the system pairing UI without running the data field view.
    public function getSensorDelegate() as Sensor.SensorDelegate or Null {
        return new AerosenseSensorDelegate();
    }

}

function getApp() as AerosenseApp {
    return Application.getApp() as AerosenseApp;
}
