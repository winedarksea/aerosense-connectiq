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

    public function initialize() {
        AppBase.initialize();
    }

    public function onStart(state as Dictionary?) as Void {
        _model = new TelemetryModel();
        _profileManager = new ProfileManager();
        _bleDelegate = new AerosenseBleDelegate(_profileManager, _model);

        BluetoothLowEnergy.setDelegate(_bleDelegate);
        _profileManager.registerProfiles();

        var stored = Storage.getValue(Constants.Keys.PAIRED_SENSOR);
        if (stored != null && stored instanceof BluetoothLowEnergy.ScanResult) {
            _bleDelegate.connectTo(stored);
        }
    }

    public function onStop(state as Dictionary?) as Void {
        if (_bleDelegate != null) {
            _bleDelegate.stopScan();
        }
        _bleDelegate = null;
        _profileManager = null;
        _model = null;
    }

    public function getModel() as TelemetryModel {
        return _model;
    }

    public function getBleDelegate() as AerosenseBleDelegate {
        return _bleDelegate;
    }

    public function getProfileManager() as ProfileManager {
        return _profileManager;
    }

    public function getInitialView() as [WatchUi.Views] or [WatchUi.Views, WatchUi.InputDelegates] {
        var field = new AerosenseField(_model);
        _field = field.weak();
        return [field];
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

    //! Connect IQ 5.1 wireless-pairing hook — invoked when the user adds this
    //! data field to a screen and the system needs a pairing UI.
    public function getSensorConfigurationView(sensor as Sensor.SensorInfo)
            as [WatchUi.Views] or [WatchUi.Views, WatchUi.InputDelegates] {
        var view = new SensorConfigurationView();
        return [view, new SensorConfigurationDelegate(view)];
    }

    public function getSensorDelegate() as Sensor.SensorDelegate or Null {
        return new AerosenseSensorDelegate();
    }
}

function getApp() as AerosenseApp {
    return Application.getApp() as AerosenseApp;
}
