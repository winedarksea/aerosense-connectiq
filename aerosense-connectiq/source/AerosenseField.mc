import Toybox.Activity;
import Toybox.Application;
import Toybox.Application.Storage;
import Toybox.BluetoothLowEnergy;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.System;
import Toybox.Timer;
import Toybox.WatchUi;

//! Primary full-screen Aerosense data field. Displays CdA, wind, yaw, grade
//! in a 2×2 grid with motion/surface state chips in the header; appends a
//! native metrics row (power, HR, distance, lap) when vertical space permits;
//! writes head-unit speed back to the device when no external wheel sensor is
//! providing one; drives the FIT contributor.
class AerosenseField extends WatchUi.DataField {
    private const SPEED_WRITE_MIN_INTERVAL_MS = 900;
    private const TELEMETRY_STALE_MS = 5000;
    private const EDGE_PAD = 4;
    private const CELL_INSET = 4;
    // Minimum grid height (px) to append the native metrics row below the 2×2
    // aero grid. Tune against the simulator for each target device.
    private const LAYOUT_EXTENDED_MIN_GRID_H = 180;

    // Tap-to-coast-down state.
    private const TAP_IDLE = 0;
    private const TAP_ARMED = 1;
    private const TAP_CONFIRMED = 2;
    private const TAP_NO_LINK = 3;
    private const ARM_WINDOW_MS = 2500;
    private const CONFIRM_FEEDBACK_MS = 1200;

    // Custom GATT link flow. Connect IQ must pair against the Aerosense BLE
    // profile directly; the CSC advertisement is only for non-CIQ fallback.
    private const PAIR_SCAN_MS = 10000;
    private const PAIR_FEEDBACK_MS = 3000;
    private const LINK_IDLE = 0;
    private const LINK_SCANNING = 1;
    private const LINK_PAIRING = 2;
    private const LINK_FAILED = 3;
    private const LINK_NO_BLE = 4;

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

    private var _tapEnabled as Boolean = true;
    private var _tapState as Number = TAP_IDLE;
    private var _tapStateAtMs as Number = 0;
    private var _linkState as Number = LINK_IDLE;
    private var _linkStateAtMs as Number = 0;
    private var _pairTimer as Timer.Timer?;
    private var _pairTimerRunning as Boolean = false;

    // Cached Activity.Info fields (only available in compute(), not onUpdate()).
    private var _power as Number? = null;
    private var _heartRate as Number? = null;
    private var _distanceM as Float? = null;
    private var _lapTimeMs as Number? = null;

    public function initialize(model as TelemetryModel) {
        DataField.initialize();
        _model = model;
        _fit = new AerosenseFitContributor(self);
        _pairTimer = new Timer.Timer();
        _tapEnabled = _readTapEnabled();
    }

    public function onSettingsChanged() as Void {
        _tapEnabled = _readTapEnabled();
        if (!_tapEnabled && _tapState != TAP_IDLE) {
            _tapState = TAP_IDLE;
            WatchUi.requestUpdate();
        }
    }

    private function _readTapEnabled() as Boolean {
        var v = Application.Properties.getValue(Constants.PROP_TAP_TO_COAST_ENABLED);
        return (v == null) ? true : v;
    }

    public function onLayout(dc as Graphics.Dc) as Void {
        _width = dc.getWidth();
        _height = dc.getHeight();
    }

    public function compute(info as Activity.Info) as Void {
        _fit.compute(_model);
        _maybeWriteSpeed(info);
        _decayTapState();
        _decayLinkState();
        _maybeForwardPressureCalRequest();
        _power     = (info has :currentPower)     ? info.currentPower     : null;
        _heartRate = (info has :currentHeartRate) ? info.currentHeartRate : null;
        _distanceM = (info has :elapsedDistance)  ? info.elapsedDistance  : null;
        _lapTimeMs = (info has :timerTimeInLap)   ? info.timerTimeInLap   : null;
    }

    private function _decayTapState() as Void {
        if (_tapState == TAP_IDLE) { return; }
        var now = System.getTimer();
        var dt = now - _tapStateAtMs;
        var window = (_tapState == TAP_ARMED) ? ARM_WINDOW_MS : CONFIRM_FEEDBACK_MS;
        // System.getTimer() can wrap; treat negative deltas as elapsed.
        if (dt < 0 || dt >= window) {
            _tapState = TAP_IDLE;
            WatchUi.requestUpdate();
        }
    }

    private function _maybeForwardPressureCalRequest() as Void {
        var requested = Application.Properties.getValue(Constants.PROP_TRIGGER_PRESSURE_CAL);
        if (requested == null || !requested) {
            return;
        }
        var ble = getApp().getBleDelegate();
        if (ble == null || !ble.isConnected()) {
            // Leave the flag set; retry on next tick once linked. User is
            // by definition stationary at this point, so latency is fine.
            return;
        }
        if (ble.queuePressureCalRequest()) {
            Application.Properties.setValue(Constants.PROP_TRIGGER_PRESSURE_CAL, false);
        }
    }

    public function handleTap() as Boolean {
        var ble = getApp().getBleDelegate();
        if (ble == null || !ble.isConnected()) {
            return _startPairScan(ble);
        }

        if (!_tapEnabled) {
            return false;
        }
        var now = System.getTimer();
        if (_tapState == TAP_ARMED) {
            var dt = now - _tapStateAtMs;
            if (dt >= 0 && dt < ARM_WINDOW_MS) {
                _fireCoastDown(now);
                return true;
            }
        }
        _tapState = TAP_ARMED;
        _tapStateAtMs = now;
        WatchUi.requestUpdate();
        return true;
    }

    private function _startPairScan(ble as AerosenseBleDelegate?) as Boolean {
        if (ble == null) {
            _setLinkState(LINK_NO_BLE);
            return true;
        }

        if (_linkState == LINK_SCANNING || _linkState == LINK_PAIRING) {
            return true;
        }

        ble.setScanListener(self);
        ble.startScan();
        _setLinkState(LINK_SCANNING);
        if (_pairTimer != null) {
            _pairTimerRunning = true;
            (_pairTimer as Timer.Timer).start(method(:_onPairScanTimeout), PAIR_SCAN_MS, false);
        }
        return true;
    }

    public function onScanResult(result as BluetoothLowEnergy.ScanResult) as Void {
        if (_linkState != LINK_SCANNING) {
            return;
        }

        _stopPairTimer();
        var ble = getApp().getBleDelegate();
        if (ble == null) {
            _setLinkState(LINK_NO_BLE);
            return;
        }

        if (ble.connectTo(result)) {
            Storage.setValue(Constants.Keys.PAIRED_SENSOR, result);
            ble.setScanListener(null);
            _setLinkState(LINK_PAIRING);
        } else {
            ble.setScanListener(null);
            _setLinkState(LINK_FAILED);
        }
    }

    private function _onPairScanTimeout() as Void {
        _pairTimerRunning = false;
        if (_linkState != LINK_SCANNING && _linkState != LINK_PAIRING) {
            return;
        }

        var ble = getApp().getBleDelegate();
        if (ble != null) {
            ble.stopScan();
            ble.setScanListener(null);
        }
        _setLinkState(LINK_FAILED);
    }

    private function _stopPairTimer() as Void {
        if (_pairTimerRunning && _pairTimer != null) {
            (_pairTimer as Timer.Timer).stop();
            _pairTimerRunning = false;
        }
    }

    private function _setLinkState(state as Number) as Void {
        _linkState = state;
        _linkStateAtMs = System.getTimer();
        WatchUi.requestUpdate();
    }

    private function _decayLinkState() as Void {
        if (_linkState != LINK_FAILED && _linkState != LINK_NO_BLE) {
            return;
        }
        var dt = System.getTimer() - _linkStateAtMs;
        if (dt < 0 || dt >= PAIR_FEEDBACK_MS) {
            _linkState = LINK_IDLE;
            WatchUi.requestUpdate();
        }
    }

    private function _fireCoastDown(now as Number) as Void {
        var ble = getApp().getBleDelegate();
        var ok = (ble != null) && ble.isConnected() && ble.queueCoastDownRequest();
        _tapState = ok ? TAP_CONFIRMED : TAP_NO_LINK;
        _tapStateAtMs = now;
        WatchUi.requestUpdate();
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
        if (connected && _linkState != LINK_IDLE) {
            _stopPairTimer();
            if (ble != null) {
                ble.setScanListener(null);
            }
            _linkState = LINK_IDLE;
        }
        var fresh = connected && _model.isFresh(TELEMETRY_STALE_MS);

        var headerH = _drawHeader(dc, fg, dim, connected, fresh);

        if (!connected) {
            _drawLinkStatus(dc, fg, dim, headerH);
            return;
        }
        if (!fresh) {
            _drawStatusMessage(dc, fg, dim, headerH,
                WatchUi.loadResource(Rez.Strings.Searching) as String, null);
            return;
        }

        _drawGrid(dc, fg, dim, headerH);
    }

    private function _drawLinkStatus(dc as Graphics.Dc, fg as Number, dim as Number,
                                     headerH as Number) as Void {
        var msg = WatchUi.loadResource(Rez.Strings.NoDevice) as String;
        var hint = WatchUi.loadResource(Rez.Strings.NoDeviceHint) as String;

        if (_linkState == LINK_SCANNING) {
            msg = WatchUi.loadResource(Rez.Strings.PairScanning) as String;
            hint = null;
        } else if (_linkState == LINK_PAIRING) {
            msg = WatchUi.loadResource(Rez.Strings.PairLinking) as String;
            hint = null;
        } else if (_linkState == LINK_FAILED) {
            msg = WatchUi.loadResource(Rez.Strings.PairNotFound) as String;
        } else if (_linkState == LINK_NO_BLE) {
            msg = WatchUi.loadResource(Rez.Strings.PairNoBle) as String;
        }

        _drawStatusMessage(dc, fg, dim, headerH, msg, hint);
    }

    //! Slim top strip: status dot left, battery % right, state chips + wordmark
    //! in the middle (wordmark dropped when space is tight). When a tap-to-coast
    //! message is active it replaces the chips entirely.
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

        var contentX = dotX + dotR + 4;

        // Compute battery string so we know how much right-side space it takes.
        var battStr = null as String?;
        var battReserveW = 0;
        if (fresh && _tapState == TAP_IDLE && _model.batteryPct > 0) {
            battStr = _model.batteryPct.toString() + "%";
            battReserveW = dc.getTextWidthInPixels(battStr, font) + 4;
            dc.setColor(dim, Graphics.COLOR_TRANSPARENT);
            dc.drawText(_width - EDGE_PAD, 2, font, battStr, Graphics.TEXT_JUSTIFY_RIGHT);
        }
        var rightEdge = _width - EDGE_PAD - battReserveW;

        if (_tapState != TAP_IDLE) {
            // Tap feedback replaces wordmark and chips.
            var tapMsg = "" as String;
            var tapColor = dim;
            if (_tapState == TAP_ARMED) {
                tapMsg = WatchUi.loadResource(Rez.Strings.TapArmed) as String;
                tapColor = Graphics.COLOR_YELLOW;
            } else if (_tapState == TAP_CONFIRMED) {
                tapMsg = WatchUi.loadResource(Rez.Strings.TapConfirmed) as String;
                tapColor = Graphics.COLOR_GREEN;
            } else if (_tapState == TAP_NO_LINK) {
                tapMsg = WatchUi.loadResource(Rez.Strings.TapNoLink) as String;
                tapColor = Graphics.COLOR_RED;
            }
            dc.setColor(tapColor, Graphics.COLOR_TRANSPARENT);
            dc.drawText(contentX, 2, font, tapMsg, Graphics.TEXT_JUSTIFY_LEFT);
        } else if (connected && fresh) {
            // Wordmark + motion/surface chips. Drop wordmark when space is tight.
            var mCode = _model.motionCode();
            var sCode = _model.surfaceCode();
            var chipPad = 3;
            var mChipW = dc.getTextWidthInPixels(mCode, font) + 2 * chipPad;
            var sChipW = dc.getTextWidthInPixels(sCode, font) + 2 * chipPad;
            var available = rightEdge - contentX;
            var wordmarkW = dc.getTextWidthInPixels("AEROSENSE", font);
            var cx = contentX;
            if (wordmarkW + 6 + mChipW + 4 + sChipW <= available) {
                dc.setColor(dim, Graphics.COLOR_TRANSPARENT);
                dc.drawText(cx, 2, font, "AEROSENSE", Graphics.TEXT_JUSTIFY_LEFT);
                cx += wordmarkW + 6;
            }
            var chipY = (headerH - fontH) / 2;
            _drawChip(dc, cx, chipY, mChipW, fontH, _model.motionColor(), mCode, font);
            cx += mChipW + 4;
            _drawChip(dc, cx, chipY, sChipW, fontH, _model.surfaceColor(), sCode, font);
        } else {
            dc.setColor(dim, Graphics.COLOR_TRANSPARENT);
            dc.drawText(contentX, 2, font, "AEROSENSE", Graphics.TEXT_JUSTIFY_LEFT);
        }

        // Underline divider.
        dc.setColor(dim, Graphics.COLOR_TRANSPARENT);
        dc.drawLine(EDGE_PAD, headerH, _width - EDGE_PAD, headerH);

        return headerH;
    }

    private function _drawChip(dc as Graphics.Dc, x as Number, y as Number,
                               w as Number, h as Number, bgColor as Number,
                               code as String, font as Graphics.FontDefinition) as Void {
        dc.setColor(bgColor, Graphics.COLOR_TRANSPARENT);
        dc.fillRectangle(x, y, w, h);
        var textColor = (bgColor == Graphics.COLOR_RED   ||
                         bgColor == Graphics.COLOR_BLUE  ||
                         bgColor == Graphics.COLOR_DK_GRAY ||
                         bgColor == Graphics.COLOR_PURPLE)
            ? Graphics.COLOR_WHITE : Graphics.COLOR_BLACK;
        dc.setColor(textColor, Graphics.COLOR_TRANSPARENT);
        dc.drawText(x + w / 2, y, font, code, Graphics.TEXT_JUSTIFY_CENTER);
    }

    //! Centered status message in the area below the header. Optional hint
    //! line is drawn beneath in a smaller dim font.
    private function _drawStatusMessage(dc as Graphics.Dc, fg as Number, dim as Number,
                                        headerH as Number, msg as String,
                                        hint as String?) as Void {
        var font = _pickStatusFont(dc, msg);
        var fontH = Graphics.getFontHeight(font);
        var hintFont = Graphics.FONT_XTINY;
        var hintH = (hint != null) ? Graphics.getFontHeight(hintFont) : 0;
        var hintGap = (hint != null) ? 4 : 0;
        var blockH = fontH + hintGap + hintH;
        var top = headerH + (_height - headerH) / 2 - blockH / 2;

        dc.setColor(fg, Graphics.COLOR_TRANSPARENT);
        dc.drawText(_width / 2, top, font, msg, Graphics.TEXT_JUSTIFY_CENTER);

        if (hint != null) {
            dc.setColor(dim, Graphics.COLOR_TRANSPARENT);
            dc.drawText(_width / 2, top + fontH + hintGap, hintFont, hint,
                Graphics.TEXT_JUSTIFY_CENTER);
        }
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

    //! 2-row × 2-column aero grid below the header. Appends a 4-cell native
    //! metrics row when the available vertical space meets the threshold.
    private function _drawGrid(dc as Graphics.Dc, fg as Number, dim as Number,
                               headerH as Number) as Void {
        var top = headerH + 1;
        var bot = _height - EDGE_PAD;
        var left = EDGE_PAD;
        var right = _width - EDGE_PAD;
        var mid = (left + right) / 2;
        var gridH = bot - top;
        var extended = (gridH >= LAYOUT_EXTENDED_MIN_GRID_H);

        var totalRows = extended ? 3 : 2;
        var ySplits = new [totalRows + 1];
        for (var i = 0; i <= totalRows; i++) {
            ySplits[i] = top + (gridH * i) / totalRows;
        }

        var grade = _model.gradePct;
        var gradeColor = fg;
        if (grade > GRADE_FLAT_THRESHOLD) {
            gradeColor = COLOR_CLIMB;
        } else if (grade < -GRADE_FLAT_THRESHOLD) {
            gradeColor = COLOR_DESCENT;
        }

        // Row 0: CDA | WIND
        _drawCell(dc, COLOR_ACCENT, dim, left, ySplits[0], mid - left,  ySplits[1] - ySplits[0],
                  WatchUi.loadResource(Rez.Strings.label_cda) as String,
                  _model.cda.format("%.3f"));
        _drawCell(dc, fg, dim, mid, ySplits[0], right - mid, ySplits[1] - ySplits[0],
                  WatchUi.loadResource(Rez.Strings.label_wind) as String,
                  _model.airspeedMps.format("%.1f"));

        // Row 1: YAW | GRADE
        _drawCell(dc, fg, dim, left, ySplits[1], mid - left,  ySplits[2] - ySplits[1],
                  WatchUi.loadResource(Rez.Strings.label_yaw) as String,
                  _model.yawValid() ? _model.yawDeg.format("%+.0f") + "°" : "—");
        _drawCell(dc, gradeColor, dim, mid, ySplits[1], right - mid, ySplits[2] - ySplits[1],
                  WatchUi.loadResource(Rez.Strings.label_grade) as String,
                  grade.format("%+.1f"));

        // Aero dividers: center vertical covers only the aero rows.
        dc.setColor(dim, Graphics.COLOR_TRANSPARENT);
        dc.drawLine(mid, ySplits[0], mid, ySplits[2]);
        dc.drawLine(left, ySplits[1], right, ySplits[1]);

        if (extended) {
            dc.drawLine(left, ySplits[2], right, ySplits[2]);
            _drawNativeRow(dc, fg, dim, left, right, ySplits[2], ySplits[3] - ySplits[2]);
        }
    }

    private function _drawNativeRow(dc as Graphics.Dc, fg as Number, dim as Number,
                                    left as Number, right as Number,
                                    y as Number, h as Number) as Void {
        var statute = (System.getDeviceSettings().distanceUnits == System.UNIT_STATUTE);
        var distLabel = statute ? "DIST MI" : "DIST KM";
        var cells = 4;
        var xs = new [cells + 1];
        for (var i = 0; i <= cells; i++) {
            xs[i] = left + ((right - left) * i) / cells;
        }
        _drawCell(dc, fg, dim, xs[0], y, xs[1] - xs[0], h,
                  WatchUi.loadResource(Rez.Strings.label_power) as String,
                  _fmtPower(_power));
        _drawCell(dc, fg, dim, xs[1], y, xs[2] - xs[1], h,
                  WatchUi.loadResource(Rez.Strings.label_hr) as String,
                  _fmtHr(_heartRate));
        _drawCell(dc, fg, dim, xs[2], y, xs[3] - xs[2], h,
                  distLabel,
                  _fmtDistance(_distanceM, statute));
        _drawCell(dc, fg, dim, xs[3], y, xs[4] - xs[3], h,
                  WatchUi.loadResource(Rez.Strings.label_lap) as String,
                  _fmtLapTime(_lapTimeMs));
        dc.setColor(dim, Graphics.COLOR_TRANSPARENT);
        for (var i = 1; i < cells; i++) {
            dc.drawLine(xs[i], y, xs[i], y + h);
        }
    }

    private function _fmtPower(p as Number?) as String {
        return (p == null) ? "—" : p.toString();
    }

    private function _fmtHr(hr as Number?) as String {
        return (hr == null) ? "—" : hr.toString();
    }

    private function _fmtDistance(m as Float?, statute as Boolean) as String {
        if (m == null) { return "—"; }
        var v = statute ? (m / 1609.344) : (m / 1000.0);
        return v.format("%.2f");
    }

    private function _fmtLapTime(ms as Number?) as String {
        if (ms == null) { return "—"; }
        var s = ms / 1000;
        var h = s / 3600;
        var m = (s / 60) % 60;
        var sec = s % 60;
        if (h > 0) {
            return h.format("%d") + ":" + m.format("%02d") + ":" + sec.format("%02d");
        }
        return m.format("%d") + ":" + sec.format("%02d");
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
