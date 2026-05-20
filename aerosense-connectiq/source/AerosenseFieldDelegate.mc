import Toybox.Lang;
import Toybox.WatchUi;

//! Routes Edge touch events to the data field. DataField itself does not
//! receive tap callbacks; the companion input delegate does.
class AerosenseFieldDelegate extends WatchUi.InputDelegate {
    private var _field as AerosenseField;

    public function initialize(field as AerosenseField) {
        InputDelegate.initialize();
        _field = field;
    }

    public function onTap(evt as WatchUi.ClickEvent) as Boolean {
        return _field.handleTap();
    }
}
