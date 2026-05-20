import Toybox.Application.Storage;
import Toybox.Lang;
import Toybox.WatchUi;

//! Configuration menu shown when the user adds the AerosenseField to a screen.
//! Editable setup items for rider+bike+gear mass and wheel circumference.
class SensorConfigurationView extends WatchUi.Menu2 {
    public static const ITEM_MASS = "mass";
    public static const ITEM_WHEEL_CIRC = "wheel_circ";

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

        var storedWheelCirc = Storage.getValue(Constants.Keys.WHEEL_CIRC_MM);
        var wheelCirc = (storedWheelCirc == null)
            ? Constants.DEFAULT_WHEEL_CIRC_MM
            : (storedWheelCirc as Number);
        addItem(new MenuItem(
            WatchUi.loadResource(Rez.Strings.WheelCircMm) as String,
            wheelCirc.toString() + " mm",
            ITEM_WHEEL_CIRC,
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

    public function setWheelCircMm(mm as Number) as Void {
        var idx = findItemById(ITEM_WHEEL_CIRC);
        if (idx >= 0) {
            var item = getItem(idx) as MenuItem;
            item.setSubLabel(mm.toString() + " mm");
        }
    }
}
