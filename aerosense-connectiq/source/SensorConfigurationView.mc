import Toybox.Application.Storage;
import Toybox.Lang;
import Toybox.WatchUi;

//! Configuration menu shown when the user adds the AerosenseField to a screen.
//! Editable setup items for rider+bike+gear mass plus service actions.
class SensorConfigurationView extends WatchUi.Menu2 {
    public static const ITEM_MASS = "mass";
    public static const ITEM_PRESSURE_CAL = "pressure_cal";

    public function initialize() {
        Menu2.initialize({:title => WatchUi.loadResource(Rez.Strings.ConfigTitle) as String});
        var storedMass = Storage.getValue(Constants.Keys.MASS_KG);
        var mass = (storedMass == null) ? Constants.DEFAULT_MASS_KG : (storedMass as Number);
        addItem(new MenuItem(
            WatchUi.loadResource(Rez.Strings.MassKg) as String,
            mass.toString() + " kg",
            ITEM_MASS,
            null
        ));
        addItem(new MenuItem(
            WatchUi.loadResource(Rez.Strings.PressureCal) as String,
            null,
            ITEM_PRESSURE_CAL,
            null
        ));
    }

    public function setMass(kg as Number) as Void {
        var idx = findItemById(ITEM_MASS);
        if (idx >= 0) {
            var item = getItem(idx) as MenuItem;
            item.setSubLabel(kg.toString() + " kg");
        }
    }

    public function setPressureCalResult(queued as Boolean) as Void {
        var idx = findItemById(ITEM_PRESSURE_CAL);
        if (idx >= 0) {
            var item = getItem(idx) as MenuItem;
            var label = queued
                ? WatchUi.loadResource(Rez.Strings.RequestQueued) as String
                : WatchUi.loadResource(Rez.Strings.RequestNoLink) as String;
            item.setSubLabel(label);
        }
    }
}
