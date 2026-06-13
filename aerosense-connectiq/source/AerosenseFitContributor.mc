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

    // Nullable: a single createField() that throws must not take the whole
    // contributor down with it (the cause of the empty FIT in testing — the
    // constructor threw, AerosenseField caught it, and _fit became null so
    // *nothing* was recorded). Each field is created independently below.
    private var _cdaRecord as FitContributor.Field?;
    private var _windRecord as FitContributor.Field?;
    private var _yawRecord as FitContributor.Field?;
    private var _gradeRecord as FitContributor.Field?;
    private var _humidityRecord as FitContributor.Field?;
    private var _motionRecord as FitContributor.Field?;
    private var _surfaceRecord as FitContributor.Field?;
    private var _cdaLap as FitContributor.Field?;
    private var _cdaSession as FitContributor.Field?;

    private var _cdaLapSum as Float = 0.0;
    private var _cdaSessionSum as Float = 0.0;
    private var _lapCount as Number = 0;
    private var _sessionCount as Number = 0;
    private var _timerRunning as Boolean = false;

    public function initialize(field as WatchUi.DataField) {
        _cdaRecord = _tryCreate(field, "cda",      FIELD_CDA_RECORD,      FitContributor.DATA_TYPE_UINT16,
            { :mesgType => FitContributor.MESG_TYPE_RECORD, :units => "m^2" });
        _windRecord = _tryCreate(field, "wind",    FIELD_WIND_RECORD,     FitContributor.DATA_TYPE_UINT16,
            { :mesgType => FitContributor.MESG_TYPE_RECORD, :units => "m/s" });
        _yawRecord = _tryCreate(field, "yaw",      FIELD_YAW_RECORD,      FitContributor.DATA_TYPE_SINT16,
            { :mesgType => FitContributor.MESG_TYPE_RECORD, :units => "deg" });
        _gradeRecord = _tryCreate(field, "grade",  FIELD_GRADE_RECORD,    FitContributor.DATA_TYPE_SINT16,
            { :mesgType => FitContributor.MESG_TYPE_RECORD, :units => "%" });
        _humidityRecord = _tryCreate(field, "hum", FIELD_HUMIDITY_RECORD, FitContributor.DATA_TYPE_UINT16,
            { :mesgType => FitContributor.MESG_TYPE_RECORD, :units => "%" });
        _motionRecord = _tryCreate(field, "motion",  FIELD_MOTION_RECORD,  FitContributor.DATA_TYPE_UINT8,
            { :mesgType => FitContributor.MESG_TYPE_RECORD });
        _surfaceRecord = _tryCreate(field, "surf",   FIELD_SURFACE_RECORD, FitContributor.DATA_TYPE_UINT8,
            { :mesgType => FitContributor.MESG_TYPE_RECORD });
        _cdaLap = _tryCreate(field, "cdaLap",         FIELD_CDA_LAP_AVG,     FitContributor.DATA_TYPE_UINT16,
            { :mesgType => FitContributor.MESG_TYPE_LAP, :units => "m^2" });
        _cdaSession = _tryCreate(field, "cdaSession", FIELD_CDA_SESSION_AVG, FitContributor.DATA_TYPE_UINT16,
            { :mesgType => FitContributor.MESG_TYPE_SESSION, :units => "m^2" });
    }

    //! Create one developer field, isolating any failure so the remaining fields
    //! are still registered (and still appear in the FIT). Returns null on throw.
    private function _tryCreate(field as WatchUi.DataField, name as String, id as Number,
                               type as FitContributor.DataType, opts as Dictionary) as FitContributor.Field? {
        try {
            return field.createField(name, id, type, opts);
        } catch (e) {
            System.println("Aerosense FIT field '" + name + "' failed: " + e.getErrorMessage());
            return null;
        }
    }

    public function compute(model as TelemetryModel) as Void {
        if (!model.isFresh(5000)) {
            return;
        }

        _setField(_cdaRecord, toFixed(model.cda, SCALE_CDA));
        _setField(_windRecord, toFixed(model.airspeedMps, SCALE_WIND));
        _setField(_yawRecord, toSignedFixed(model.yawDeg, SCALE_YAW));
        _setField(_gradeRecord, toSignedFixed(model.gradePct, SCALE_GRADE));
        _setField(_humidityRecord, toFixed(model.humidityPct, SCALE_HUMIDITY));
        _setField(_motionRecord, model.motion);
        _setField(_surfaceRecord, model.surface);

        if (_timerRunning && model.cda > 0.0) {
            _cdaLapSum += model.cda;
            _cdaSessionSum += model.cda;
            _lapCount++;
            _sessionCount++;
            _setField(_cdaLap, toFixed(_cdaLapSum / _lapCount, SCALE_CDA));
            _setField(_cdaSession, toFixed(_cdaSessionSum / _sessionCount, SCALE_CDA));
        }
    }

    private function _setField(f as FitContributor.Field?, value as Number) as Void {
        if (f != null) {
            f.setData(value);
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
