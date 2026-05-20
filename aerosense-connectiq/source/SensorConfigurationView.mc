import Toybox.Application.Storage;
import Toybox.Lang;
import Toybox.WatchUi;

//! Configuration menu shown when the user adds the AerosenseField to a screen.
//! Single editable item for rider+bike+gear mass (kg).
class SensorConfigurationView extends WatchUi.Menu2 {
    public static const ITEM_MASS = "mass";

    public function initialize() {
        Menu2.initialize({:title => WatchUi.loadResource(Rez.Strings.ConfigTitle) as String});
        var stored = Storage.getValue(Constants.Keys.MASS_KG);
        var mass = (stored == null) ? Constants.DEFAULT_MASS_KG : (stored as Number);
        addItem(new MenuItem(
            WatchUi.loadResource(Rez.Strings.MassKg) as String,
            mass.toString() + " kg",
            ITEM_MASS,
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
}
