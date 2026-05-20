import Toybox.Activity;
import Toybox.Application;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.System;
import Toybox.WatchUi;

//! Primary full-screen Aerosense data field. Displays CdA, wind, yaw, grade,
//! humidity, motion/surface; writes head-unit speed back to the device when no
//! external wheel sensor is providing one; drives the FIT contributor.
class AerosenseField extends WatchUi.DataField {
    private const SPEED_WRITE_MIN_INTERVAL_MS = 900;
    private const TELEMETRY_STALE_MS = 5000;
    private const EDGE_PAD = 4;
    private const CELL_INSET = 4;

    // Accent colors. All targeted Edge devices have full color.
    private const COLOR_ACCENT  = Graphics.COLOR_YELLOW;   // CdA — the marquee value
    private const COLOR_CLIMB   = Graphics.COLOR_ORANGE;   // positive grade
    private const COLOR_DESCENT = Graphics.COLOR_GREEN;    // negative grade
    private const GRADE_FLAT_THRESHOLD = 0.3;              // % below which we draw grade in white

    private var _model as TelemetryModel;
    private var _fit as AerosenseFitContributor;

    private var _lastSpeedWriteMs as Number = 0;
    private var _width as Number = 0;
    private var _height as Number = 0;

    public function initialize(model as TelemetryModel) {
        DataField.initialize();
        _model = model;
        _fit = new AerosenseFitContributor(self);
    }

    public function onLayout(dc as Graphics.Dc) as Void {
        _width = dc.getWidth();
        _height = dc.getHeight();
    }

    public function compute(info as Activity.Info) as Void {
        _fit.compute(_model);
        _maybeWriteSpeed(info);
    }

    private function _maybeWriteSpeed(info as Activity.Info) as Void {
        if (!(info has :currentSpeed)) { return; }
        var s = info.currentSpeed;
        if (s == null || s <= 0.5) { return; }

        var now = System.getTimer();
        if (_lastSpeedWriteMs != 0) {
            var dt = now - _lastSpeedWriteMs;
            // getTimer() wraps; only apply throttle for non-negative deltas.
            if (dt >= 0 && dt < SPEED_WRITE_MIN_INTERVAL_MS) {
                return;
            }
        }
        if (_model.hasExternalSpeed()) {
            return;
        }

        var ble = getApp().getBleDelegate();
        if (ble == null || !ble.isConnected()) {
            return;
        }
        if (ble.writeSpeedMps(s)) {
            _lastSpeedWriteMs = now;
        }
    }

    public function onUpdate(dc as Graphics.Dc) as Void {
        var bg = getBackgroundColor();
        var fg = (bg == Graphics.COLOR_WHITE) ? Graphics.COLOR_BLACK : Graphics.COLOR_WHITE;
        var dim = (bg == Graphics.COLOR_WHITE) ? Graphics.COLOR_DK_GRAY : Graphics.COLOR_LT_GRAY;

        dc.setColor(fg, bg);
        dc.clear();

        var ble = getApp().getBleDelegate();
        var connected = (ble != null) && ble.isConnected();
        var fresh = connected && _model.isFresh(TELEMETRY_STALE_MS);

        var headerH = _drawHeader(dc, fg, dim, connected, fresh);

        if (!connected) {
            _drawStatusMessage(dc, fg, headerH, WatchUi.loadResource(Rez.Strings.NoDevice) as String);
            return;
        }
        if (!fresh) {
            _drawStatusMessage(dc, fg, headerH, WatchUi.loadResource(Rez.Strings.Searching) as String);
            return;
        }

        _drawGrid(dc, fg, dim, headerH);
    }

    //! Slim top strip: status dot + "AEROSENSE" wordmark left, battery % right.
    //! Returns the strip's height in px so the grid knows where to start.
    private function _drawHeader(dc as Graphics.Dc, fg as Number, dim as Number,
                                 connected as Boolean, fresh as Boolean) as Number {
        var font = Graphics.FONT_XTINY;
        var fontH = Graphics.getFontHeight(font);
        var headerH = fontH + 4;

        var dotColor = connected
            ? (fresh ? Graphics.COLOR_GREEN : Graphics.COLOR_ORANGE)
            : Graphics.COLOR_RED;
        var dotR = (fontH / 4).toNumber();
        if (dotR < 3) { dotR = 3; }
        var dotX = EDGE_PAD + dotR;
        var dotY = headerH / 2;

        dc.setColor(dotColor, Graphics.COLOR_TRANSPARENT);
        dc.fillCircle(dotX, dotY, dotR);

        dc.setColor(dim, Graphics.COLOR_TRANSPARENT);
        dc.drawText(dotX + dotR + 4, 2, font, "AEROSENSE", Graphics.TEXT_JUSTIFY_LEFT);

        if (fresh) {
            var batt = _model.batteryPct;
            if (batt > 0) {
                dc.drawText(_width - EDGE_PAD, 2, font, batt.toString() + "%",
                    Graphics.TEXT_JUSTIFY_RIGHT);
            }
        }

        // Underline divider.
        dc.drawLine(EDGE_PAD, headerH, _width - EDGE_PAD, headerH);

        return headerH;
    }

    //! Centered single-line status message in the area below the header.
    private function _drawStatusMessage(dc as Graphics.Dc, fg as Number,
                                        headerH as Number, msg as String) as Void {
        dc.setColor(fg, Graphics.COLOR_TRANSPARENT);
        var font = _pickStatusFont(dc, msg);
        var y = headerH + (_height - headerH) / 2 - Graphics.getFontHeight(font) / 2;
        dc.drawText(_width / 2, y, font, msg, Graphics.TEXT_JUSTIFY_CENTER);
    }

    private function _pickStatusFont(dc as Graphics.Dc, msg as String) as Graphics.FontDefinition {
        var candidates = [Graphics.FONT_LARGE, Graphics.FONT_MEDIUM,
                          Graphics.FONT_SMALL, Graphics.FONT_TINY];
        var maxW = _width - 2 * EDGE_PAD;
        for (var i = 0; i < candidates.size(); i++) {
            if (dc.getTextWidthInPixels(msg, candidates[i]) <= maxW) {
                return candidates[i];
            }
        }
        return Graphics.FONT_XTINY;
    }

    //! 3-row × 2-column grid covering the area below the header strip.
    private function _drawGrid(dc as Graphics.Dc, fg as Number, dim as Number,
                               headerH as Number) as Void {
        var top = headerH + 1;
        var bot = _height - EDGE_PAD;
        var left = EDGE_PAD;
        var right = _width - EDGE_PAD;
        var mid = (left + right) / 2;

        var ySplits = [top,
                       top + (bot - top) / 3,
                       top + (2 * (bot - top)) / 3,
                       bot];

        var grade = _model.gradePct;
        var gradeColor = fg;
        if (grade > GRADE_FLAT_THRESHOLD) {
            gradeColor = COLOR_CLIMB;
        } else if (grade < -GRADE_FLAT_THRESHOLD) {
            gradeColor = COLOR_DESCENT;
        }

        _drawCell(dc, COLOR_ACCENT, dim, left,  ySplits[0], mid - left,    ySplits[1] - ySplits[0],
                  WatchUi.loadResource(Rez.Strings.label_cda) as String,
                  _model.cda.format("%.3f"));
        _drawCell(dc, fg,           dim, mid,   ySplits[0], right - mid,   ySplits[1] - ySplits[0],
                  WatchUi.loadResource(Rez.Strings.label_wind) as String,
                  _model.airspeedMps.format("%.1f"));

        _drawCell(dc, fg,           dim, left,  ySplits[1], mid - left,    ySplits[2] - ySplits[1],
                  WatchUi.loadResource(Rez.Strings.label_yaw) as String,
                  _model.yawValid() ? _model.yawDeg.format("%+.0f") + "°" : "—");
        _drawCell(dc, gradeColor,   dim, mid,   ySplits[1], right - mid,   ySplits[2] - ySplits[1],
                  WatchUi.loadResource(Rez.Strings.label_grade) as String,
                  grade.format("%+.1f"));

        _drawCell(dc, fg,           dim, left,  ySplits[2], mid - left,    ySplits[3] - ySplits[2],
                  WatchUi.loadResource(Rez.Strings.label_humidity) as String,
                  _model.humidityPct.toString());
        _drawCell(dc, fg,           dim, mid,   ySplits[2], right - mid,   ySplits[3] - ySplits[2],
                  WatchUi.loadResource(Rez.Strings.label_state) as String,
                  _model.motionLabel() + "/" + _model.surfaceLabel());

        dc.setColor(dim, Graphics.COLOR_TRANSPARENT);
        dc.drawLine(mid, ySplits[0], mid, ySplits[3]);
        dc.drawLine(left, ySplits[1], right, ySplits[1]);
        dc.drawLine(left, ySplits[2], right, ySplits[2]);
    }

    private function _drawCell(dc as Graphics.Dc, valueColor as Number, labelColor as Number,
                               x as Number, y as Number, w as Number, h as Number,
                               label as String, value as String) as Void {
        var labelFont = Graphics.FONT_XTINY;
        var labelH = Graphics.getFontHeight(labelFont);
        var valueAreaH = h - labelH - 2 * CELL_INSET;
        var valueAreaW = w - 2 * CELL_INSET;
        var valueFont = _selectValueFont(dc, value, valueAreaW, valueAreaH);
        var valueH = Graphics.getFontHeight(valueFont);

        dc.setColor(labelColor, Graphics.COLOR_TRANSPARENT);
        dc.drawText(x + w / 2, y + CELL_INSET / 2, labelFont, label, Graphics.TEXT_JUSTIFY_CENTER);

        dc.setColor(valueColor, Graphics.COLOR_TRANSPARENT);
        var valueY = y + labelH + CELL_INSET + (valueAreaH - valueH) / 2;
        dc.drawText(x + w / 2, valueY, valueFont, value, Graphics.TEXT_JUSTIFY_CENTER);
    }

    private function _selectValueFont(dc as Graphics.Dc, value as String,
                                      maxW as Number, maxH as Number) as Graphics.FontDefinition {
        var candidates = [Graphics.FONT_NUMBER_MEDIUM, Graphics.FONT_NUMBER_MILD,
                          Graphics.FONT_LARGE, Graphics.FONT_MEDIUM, Graphics.FONT_SMALL,
                          Graphics.FONT_TINY, Graphics.FONT_XTINY];
        for (var i = 0; i < candidates.size(); i++) {
            var dims = dc.getTextDimensions(value, candidates[i]);
            if (dims[0] <= maxW && dims[1] <= maxH) {
                return candidates[i];
            }
        }
        return Graphics.FONT_XTINY;
    }

    public function onTimerStart()  as Void { _fit.setTimerRunning(true); }
    public function onTimerStop()   as Void { _fit.setTimerRunning(false); }
    public function onTimerPause()  as Void { _fit.setTimerRunning(false); }
    public function onTimerResume() as Void { _fit.setTimerRunning(true); }
    public function onTimerLap()    as Void { _fit.onTimerLap(); }
    public function onTimerReset()  as Void { _fit.onTimerReset(); }
}
