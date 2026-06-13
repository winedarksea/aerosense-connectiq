import Toybox.Graphics;
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
// v2 compact notify (current firmware, 20 bytes, no version prefix):
//   off  size  field
//     0    16  v1 layout above
//    16     2  grade_centi_pct
//    18     1  humidity_pct
//    19     1  state              bits 0..2=motion, bits 3..4=surface,
//                                 bits 5..6=speed_source
//
// v2a full GATT read (24 bytes, no version prefix):
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
    private const V2_COMPACT_NOTIFY_LEN = 20;
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
        var compactNotify = false;

        if (len >= V2_PREFIXED_LEN && data[0] == 0x02) {
            version = 2;
            base = 1;
            hasExtended = true;
        } else if (len >= V2_UNPREFIXED_LEN) {
            version = 2;
            base = 0;
            hasExtended = true;
        } else if (len >= V2_COMPACT_NOTIFY_LEN) {
            version = 2;
            base = 0;
            hasExtended = true;
            compactNotify = true;
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
            var gradeOffset = base + 20;
            if (compactNotify) {
                gradeOffset = base + 16;
                humidityPct = data.decodeNumber(Lang.NUMBER_FORMAT_UINT8, {:offset => base + 18});
                var state = data.decodeNumber(Lang.NUMBER_FORMAT_UINT8, {:offset => base + 19});
                motion = state & 0x07;
                surface = (state >> 3) & 0x03;
                speedSource = (state >> 5) & 0x03;
            } else {
                humidityPct = data.decodeNumber(Lang.NUMBER_FORMAT_UINT8, {:offset => base + 16});
                motion      = data.decodeNumber(Lang.NUMBER_FORMAT_UINT8, {:offset => base + 17});
                surface     = data.decodeNumber(Lang.NUMBER_FORMAT_UINT8, {:offset => base + 18});
                speedSource = data.decodeNumber(Lang.NUMBER_FORMAT_UINT8, {:offset => base + 19});
            }
            var gradeCenti = data.decodeNumber(Lang.NUMBER_FORMAT_SINT16, {:offset => gradeOffset, :endianness => Lang.ENDIAN_LITTLE});
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

    //! Compact device-mode code for the header strip. Matches enum aero_mode in
    //! src/app/state.h.
    public function modeCode() as String {
        switch (mode) {
            case 0: return "IDLE";
            case 1: return "RIDE";
            case 2: return "PAIR";
            case 3: return "CMAN";
            case 4: return "CAUT";
            case 5: return "EXPT";
            case 6: return "PCAL";
            case 7: return "SLP";
        }
        return "—";
    }

    //! Compact CdA-status code (the validity gate that is suppressing CdA).
    //! Matches enum aero_cda_status in src/app/state.h.
    public function cdaStatusCode() as String {
        switch (cdaStatus) {
            case 0: return "OK";
            case 1: return "NOSPD";
            case 2: return "STPWR";
            case 3: return "LOSPD";
            case 4: return "LOPWR";
            case 5: return "ACCEL";
            case 6: return "BADPR";
            case 7: return "NORHO";
            case 8: return "NORID";
        }
        return "?";
    }

    //! Compact speed-source code. Matches enum aero_speed_source in state.h.
    public function speedSourceCode() as String {
        switch (speedSource) {
            case 1: return "P";   // BLE peripheral write (head unit)
            case 2: return "S";   // ANT+ / BLE central wheel sensor
        }
        return "0";               // none
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

    public function motionCode() as String {
        switch (motion) {
            case 0: return "STL";
            case 1: return "BRK";
            case 2: return "CST";
            case 3: return "PDL";
            case 4: return "STD";
            case 5: return "RUN";
        }
        return "—";
    }

    public function motionColor() as Number {
        switch (motion) {
            case 0: return Graphics.COLOR_DK_GRAY;
            case 1: return Graphics.COLOR_RED;
            case 2: return Graphics.COLOR_BLUE;
            case 3: return Graphics.COLOR_GREEN;
            case 4: return Graphics.COLOR_ORANGE;
            case 5: return Graphics.COLOR_PURPLE;
        }
        return Graphics.COLOR_DK_GRAY;
    }

    public function surfaceCode() as String {
        switch (surface) {
            case 0: return "SMO";
            case 1: return "RGH";
            case 2: return "GVL";
            case 3: return "RKY";
        }
        return "—";
    }

    public function surfaceColor() as Number {
        switch (surface) {
            case 0: return Graphics.COLOR_WHITE;
            case 1: return Graphics.COLOR_YELLOW;
            case 2: return Graphics.COLOR_ORANGE;
            case 3: return Graphics.COLOR_RED;
        }
        return Graphics.COLOR_DK_GRAY;
    }
}
