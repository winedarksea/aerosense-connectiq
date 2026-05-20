import Toybox.Lang;
import Toybox.System;

// Telemetry layout (LE), matches firmware src/ble/ble.c struct aerosense_telemetry.
//
// v1 (legacy, 16 bytes — no version prefix):
//   off  size  field
//     0     1  mode
//     1     1  battery_pct
//     2     1  cda_status
//     3     1  flags             bit0=yaw_valid, bit1=peer_connected,
//                                 bit2=vbus_present, bit3=external_speed_fresh
//     4     2  power_w           u16
//     6     2  speed_cms         u16, cm/s
//     8     2  yaw_deci_deg      i16, deg * 10
//    10     2  cda_milli         u16, CdA * 1000
//    12     2  airspeed_cms      u16, cm/s
//    14     2  battery_mv        u16, mV
//
// v2a (current firmware, 24 bytes, no version prefix):
//   off  size  field
//     0     1  mode
//     1     1  battery_pct
//     2     1  cda_status
//     3     1  flags
//     4     2  power_w
//     6     2  speed_cms
//     8     2  yaw_deci_deg
//    10     2  cda_milli
//    12     2  airspeed_cms
//    14     2  battery_mv
//    16     1  humidity_pct
//    17     1  motion
//    18     1  surface
//    19     1  speed_source
//    20     2  grade_centi_pct
//    22     2  reserved
//
// v2b (prefixed with version=0x02):
//   off  size  field
//     0     1  version (0x02)
//     1    16  v1 layout above
//    17     1  humidity_pct
//    18     1  motion             enum aero_motion_class
//    19     1  surface            enum aero_surface_class
//    20     1  speed_source       0=none, 1=peer, 2=sensor
//    21     2  grade_centi_pct    i16, grade% * 100
//    23     2  reserved
class TelemetryModel {
    private const V1_LEN = 16;
    private const V2_UNPREFIXED_LEN = 24;
    private const V2_PREFIXED_LEN = 25;

    public var version as Number = 0;
    public var mode as Number = 0;
    public var batteryPct as Number = 0;
    public var cdaStatus as Number = 0;
    public var flags as Number = 0;

    public var powerW as Number = 0;
    public var speedMps as Float = 0.0;
    public var yawDeg as Float = 0.0;
    public var cda as Float = 0.0;
    public var airspeedMps as Float = 0.0;
    public var batteryV as Float = 0.0;

    public var humidityPct as Number = 0;
    public var motion as Number = 0;
    public var surface as Number = 0;
    public var speedSource as Number = 0;
    public var gradePct as Float = 0.0;

    public var lastUpdateMs as Number = 0;

    public function initialize() {}

    //! Parse a notify payload. Returns true if any known layout matched.
    public function parse(data as ByteArray) as Boolean {
        var len = data.size();
        var base = 0;
        var hasExtended = false;

        if (len >= V2_PREFIXED_LEN && data[0] == 0x02) {
            version = 2;
            base = 1;
            hasExtended = true;
        } else if (len >= V2_UNPREFIXED_LEN) {
            version = 2;
            base = 0;
            hasExtended = true;
        } else if (len >= V1_LEN) {
            version = 1;
            base = 0;
        } else {
            return false;
        }

        mode       = data.decodeNumber(Lang.NUMBER_FORMAT_UINT8, {:offset => base + 0});
        batteryPct = data.decodeNumber(Lang.NUMBER_FORMAT_UINT8, {:offset => base + 1});
        cdaStatus  = data.decodeNumber(Lang.NUMBER_FORMAT_UINT8, {:offset => base + 2});
        flags      = data.decodeNumber(Lang.NUMBER_FORMAT_UINT8, {:offset => base + 3});

        powerW = data.decodeNumber(Lang.NUMBER_FORMAT_UINT16, {:offset => base + 4, :endianness => Lang.ENDIAN_LITTLE});
        var speedCms = data.decodeNumber(Lang.NUMBER_FORMAT_UINT16, {:offset => base + 6, :endianness => Lang.ENDIAN_LITTLE});
        speedMps = speedCms / 100.0;
        var yawDeci = data.decodeNumber(Lang.NUMBER_FORMAT_SINT16, {:offset => base + 8, :endianness => Lang.ENDIAN_LITTLE});
        yawDeg = yawDeci / 10.0;
        var cdaMilli = data.decodeNumber(Lang.NUMBER_FORMAT_UINT16, {:offset => base + 10, :endianness => Lang.ENDIAN_LITTLE});
        cda = cdaMilli / 1000.0;
        var asCms = data.decodeNumber(Lang.NUMBER_FORMAT_UINT16, {:offset => base + 12, :endianness => Lang.ENDIAN_LITTLE});
        airspeedMps = asCms / 100.0;
        var battMv = data.decodeNumber(Lang.NUMBER_FORMAT_UINT16, {:offset => base + 14, :endianness => Lang.ENDIAN_LITTLE});
        batteryV = battMv / 1000.0;

        if (hasExtended) {
            humidityPct = data.decodeNumber(Lang.NUMBER_FORMAT_UINT8, {:offset => base + 16});
            motion      = data.decodeNumber(Lang.NUMBER_FORMAT_UINT8, {:offset => base + 17});
            surface     = data.decodeNumber(Lang.NUMBER_FORMAT_UINT8, {:offset => base + 18});
            speedSource = data.decodeNumber(Lang.NUMBER_FORMAT_UINT8, {:offset => base + 19});
            var gradeCenti = data.decodeNumber(Lang.NUMBER_FORMAT_SINT16, {:offset => base + 20, :endianness => Lang.ENDIAN_LITTLE});
            gradePct = gradeCenti / 100.0;
        } else {
            humidityPct = 0;
            motion = 0;
            surface = 0;
            // No source byte in v1; infer from the existing peer_connected bit.
            speedSource = ((flags & Constants.FLAG_PEER_CONNECTED) != 0) ? 1 : 0;
            gradePct = 0.0;
        }

        lastUpdateMs = System.getTimer();
        return true;
    }

    public function isFresh(maxAgeMs as Number) as Boolean {
        if (lastUpdateMs == 0) {
            return false;
        }
        var dt = System.getTimer() - lastUpdateMs;
        // System.getTimer() wraps; treat negative deltas as fresh.
        return dt < 0 || dt <= maxAgeMs;
    }

    //! True when the device reports a real (ANT+ or BLE-central) wheel sensor
    //! is feeding speed — i.e. we should NOT write our head-unit speed back.
    public function hasExternalSpeed() as Boolean {
        return (flags & Constants.FLAG_EXTERNAL_SPEED_FRESH) != 0;
    }

    public function yawValid() as Boolean {
        return (flags & Constants.FLAG_YAW_VALID) != 0;
    }

    public function motionLabel() as String {
        // Matches enum aero_motion_state in src/app/state.h.
        switch (motion) {
            case 0: return "STILL";
            case 1: return "BRAKE";
            case 2: return "COAST";
            case 3: return "PEDAL";
            case 4: return "STAND";
            case 5: return "RUN";
        }
        return "—";
    }

    public function surfaceLabel() as String {
        // Matches enum aero_surface_state in src/app/state.h.
        switch (surface) {
            case 0: return "SMOOTH";
            case 1: return "ROUGH";
            case 2: return "GRAVEL";
            case 3: return "ROCKY";
        }
        return "—";
    }
}
