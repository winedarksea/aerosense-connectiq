import Toybox.FitContributor;
import Toybox.Lang;
import Toybox.WatchUi;

//! Persists Aerosense telemetry into the FIT file so the activity in
//! Garmin Connect / Strava carries the real aero metrics.
class AerosenseFitContributor {
    // Developer field ids — local to this app, do not need to be globally unique.
    private enum FieldId {
        FIELD_CDA_RECORD,
        FIELD_WIND_RECORD,
        FIELD_YAW_RECORD,
        FIELD_GRADE_RECORD,
        FIELD_HUMIDITY_RECORD,
        FIELD_MOTION_RECORD,
        FIELD_SURFACE_RECORD,
        FIELD_CDA_LAP_AVG,
        FIELD_CDA_SESSION_AVG
    }

    // Scales — match the on-screen formatting; FIT integer fields × scale.
    private const SCALE_CDA      = 10000;  // CdA stored as m²×10000 (4 d.p.)
    private const SCALE_WIND     = 100;    // m/s × 100
    private const SCALE_YAW      = 10;     // deg × 10
    private const SCALE_GRADE    = 100;    // % × 100
    private const SCALE_HUMIDITY = 10;     // % × 10

    private var _cdaRecord as FitContributor.Field;
    private var _windRecord as FitContributor.Field;
    private var _yawRecord as FitContributor.Field;
    private var _gradeRecord as FitContributor.Field;
    private var _humidityRecord as FitContributor.Field;
    private var _motionRecord as FitContributor.Field;
    private var _surfaceRecord as FitContributor.Field;
    private var _cdaLap as FitContributor.Field;
    private var _cdaSession as FitContributor.Field;

    private var _cdaLapSum as Float = 0.0;
    private var _cdaSessionSum as Float = 0.0;
    private var _lapCount as Number = 0;
    private var _sessionCount as Number = 0;
    private var _timerRunning as Boolean = false;

    public function initialize(field as WatchUi.DataField) {
        _cdaRecord = field.createField("cda",      FIELD_CDA_RECORD,      FitContributor.DATA_TYPE_UINT16,
            { :mesgType => FitContributor.MESG_TYPE_RECORD, :units => "m^2" });
        _windRecord = field.createField("wind",    FIELD_WIND_RECORD,     FitContributor.DATA_TYPE_UINT16,
            { :mesgType => FitContributor.MESG_TYPE_RECORD, :units => "m/s" });
        _yawRecord = field.createField("yaw",      FIELD_YAW_RECORD,      FitContributor.DATA_TYPE_SINT16,
            { :mesgType => FitContributor.MESG_TYPE_RECORD, :units => "deg" });
        _gradeRecord = field.createField("grade",  FIELD_GRADE_RECORD,    FitContributor.DATA_TYPE_SINT16,
            { :mesgType => FitContributor.MESG_TYPE_RECORD, :units => "%" });
        _humidityRecord = field.createField("hum", FIELD_HUMIDITY_RECORD, FitContributor.DATA_TYPE_UINT16,
            { :mesgType => FitContributor.MESG_TYPE_RECORD, :units => "%" });
        _motionRecord = field.createField("motion",  FIELD_MOTION_RECORD,  FitContributor.DATA_TYPE_UINT8,
            { :mesgType => FitContributor.MESG_TYPE_RECORD });
        _surfaceRecord = field.createField("surf",   FIELD_SURFACE_RECORD, FitContributor.DATA_TYPE_UINT8,
            { :mesgType => FitContributor.MESG_TYPE_RECORD });
        _cdaLap = field.createField("cdaLap",         FIELD_CDA_LAP_AVG,     FitContributor.DATA_TYPE_UINT16,
            { :mesgType => FitContributor.MESG_TYPE_LAP, :units => "m^2" });
        _cdaSession = field.createField("cdaSession", FIELD_CDA_SESSION_AVG, FitContributor.DATA_TYPE_UINT16,
            { :mesgType => FitContributor.MESG_TYPE_SESSION, :units => "m^2" });
    }

    public function compute(model as TelemetryModel) as Void {
        if (!model.isFresh(5000)) {
            return;
        }

        _cdaRecord.setData(toFixed(model.cda, SCALE_CDA));
        _windRecord.setData(toFixed(model.airspeedMps, SCALE_WIND));
        _yawRecord.setData(toSignedFixed(model.yawDeg, SCALE_YAW));
        _gradeRecord.setData(toSignedFixed(model.gradePct, SCALE_GRADE));
        _humidityRecord.setData(toFixed(model.humidityPct, SCALE_HUMIDITY));
        _motionRecord.setData(model.motion);
        _surfaceRecord.setData(model.surface);

        if (_timerRunning && model.cda > 0.0) {
            _cdaLapSum += model.cda;
            _cdaSessionSum += model.cda;
            _lapCount++;
            _sessionCount++;
            _cdaLap.setData(toFixed(_cdaLapSum / _lapCount, SCALE_CDA));
            _cdaSession.setData(toFixed(_cdaSessionSum / _sessionCount, SCALE_CDA));
        }
    }

    public function setTimerRunning(running as Boolean) as Void { _timerRunning = running; }

    public function onTimerLap() as Void {
        _cdaLapSum = 0.0;
        _lapCount = 0;
    }

    public function onTimerReset() as Void {
        _cdaLapSum = 0.0;
        _cdaSessionSum = 0.0;
        _lapCount = 0;
        _sessionCount = 0;
    }

    private function toFixed(value as Numeric, scale as Number) as Number {
        if (value < 0) { value = 0; }
        return ((value * scale) + 0.5).toNumber();
    }

    private function toSignedFixed(value as Numeric, scale as Number) as Number {
        var scaled = value * scale;
        return (scaled >= 0 ? (scaled + 0.5).toNumber() : (scaled - 0.5).toNumber());
    }
}
