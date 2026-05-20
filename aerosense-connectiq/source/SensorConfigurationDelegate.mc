import Toybox.Application.Storage;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.WatchUi;

class SensorConfigurationDelegate extends WatchUi.Menu2InputDelegate {
    private var _view as SensorConfigurationView;

    public function initialize(view as SensorConfigurationView) {
        Menu2InputDelegate.initialize();
        _view = view;
    }

    public function onSelect(item as WatchUi.MenuItem) as Void {
        if (SensorConfigurationView.ITEM_MASS.equals(item.getId())) {
            var stored = Storage.getValue(Constants.Keys.MASS_KG);
            var current = (stored == null) ? Constants.DEFAULT_MASS_KG : (stored as Number);
            WatchUi.pushView(
                new MassPicker(current),
                new MassPickerDelegate(_view),
                WatchUi.SLIDE_LEFT);
            return;
        }

        if (SensorConfigurationView.ITEM_WHEEL_CIRC.equals(item.getId())) {
            var storedWheelCirc = Storage.getValue(Constants.Keys.WHEEL_CIRC_MM);
            var currentWheelCirc = (storedWheelCirc == null)
                ? Constants.DEFAULT_WHEEL_CIRC_MM
                : (storedWheelCirc as Number);
            WatchUi.pushView(
                new WheelCircPicker(currentWheelCirc),
                new WheelCircPickerDelegate(_view),
                WatchUi.SLIDE_LEFT);
        }
    }

    public function onBack() as Void {
        WatchUi.popView(WatchUi.SLIDE_RIGHT);
    }
}

//! Whole-number kg picker, 20..200 kg.
class MassPicker extends WatchUi.Picker {
    public function initialize(currentKg as Number) {
        var factory = new RangeNumberFactory(20, 200, 1);
        Picker.initialize({
            :title => new WatchUi.Text({
                :text => WatchUi.loadResource(Rez.Strings.MassKg) as String,
                :locX => WatchUi.LAYOUT_HALIGN_CENTER,
                :locY => WatchUi.LAYOUT_VALIGN_BOTTOM,
                :color => Graphics.COLOR_WHITE
            }),
            :pattern => [factory],
            :defaults => [factory.getIndex(currentKg)]
        });
    }
}

class WheelCircPicker extends WatchUi.Picker {
    public function initialize(currentMm as Number) {
        var factory = new RangeNumberFactory(1000, 3000, 10);
        Picker.initialize({
            :title => new WatchUi.Text({
                :text => WatchUi.loadResource(Rez.Strings.WheelCircMm) as String,
                :locX => WatchUi.LAYOUT_HALIGN_CENTER,
                :locY => WatchUi.LAYOUT_VALIGN_BOTTOM,
                :color => Graphics.COLOR_WHITE
            }),
            :pattern => [factory],
            :defaults => [factory.getIndex(currentMm)]
        });
    }
}

//! Inline number factory — the SDK ships NumberFactory only as a sample.
class RangeNumberFactory extends WatchUi.PickerFactory {
    private var _start as Number;
    private var _stop as Number;
    private var _increment as Number;

    public function initialize(start as Number, stop as Number, increment as Number) {
        PickerFactory.initialize();
        _start = start;
        _stop = stop;
        _increment = increment;
    }

    public function getIndex(value as Number) as Number {
        if (value < _start) {
            value = _start;
        } else if (value > _stop) {
            value = _stop;
        }
        return (value - _start) / _increment;
    }

    public function getValue(index as Number) as Object? {
        return _start + (index * _increment);
    }

    public function getSize() as Number {
        return (_stop - _start) / _increment + 1;
    }

    public function getDrawable(index as Number, selected as Boolean) as WatchUi.Drawable? {
        var value = getValue(index) as Number;
        return new WatchUi.Text({
            :text => value.format("%d"),
            :color => Graphics.COLOR_WHITE,
            :font => Graphics.FONT_NUMBER_MILD,
            :locX => WatchUi.LAYOUT_HALIGN_CENTER,
            :locY => WatchUi.LAYOUT_VALIGN_CENTER
        });
    }
}

class MassPickerDelegate extends WatchUi.PickerDelegate {
    private var _view as SensorConfigurationView;

    public function initialize(view as SensorConfigurationView) {
        PickerDelegate.initialize();
        _view = view;
    }

    public function onAccept(values as Array) as Boolean {
        var kg = values[0] as Number;
        if (kg != null && kg > 0) {
            Storage.setValue(Constants.Keys.MASS_KG, kg);
            _view.setMass(kg);
            var ble = getApp().getBleDelegate();
            if (ble != null) {
                ble.writeMassKg(kg);
            }
        }
        WatchUi.popView(WatchUi.SLIDE_RIGHT);
        return true;
    }

    public function onCancel() as Boolean {
        WatchUi.popView(WatchUi.SLIDE_RIGHT);
        return true;
    }
}

class WheelCircPickerDelegate extends WatchUi.PickerDelegate {
    private var _view as SensorConfigurationView;

    public function initialize(view as SensorConfigurationView) {
        PickerDelegate.initialize();
        _view = view;
    }

    public function onAccept(values as Array) as Boolean {
        var mm = values[0] as Number;
        if (mm != null && mm > 0) {
            Storage.setValue(Constants.Keys.WHEEL_CIRC_MM, mm);
            _view.setWheelCircMm(mm);
            var ble = getApp().getBleDelegate();
            if (ble != null) {
                ble.writeWheelCircMm(mm);
            }
        }
        WatchUi.popView(WatchUi.SLIDE_RIGHT);
        return true;
    }

    public function onCancel() as Boolean {
        WatchUi.popView(WatchUi.SLIDE_RIGHT);
        return true;
    }
}
