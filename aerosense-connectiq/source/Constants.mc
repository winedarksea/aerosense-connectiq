import Toybox.Lang;

module Constants {
    module Keys {
        enum Key {
            PAIRED_SENSOR,
            MASS_KG
        }
    }

    // Telemetry flag bits (matches firmware src/ble/ble.c fill_telemetry()).
    const FLAG_YAW_VALID            = 0x01;
    const FLAG_PEER_CONNECTED       = 0x02;
    const FLAG_VBUS_PRESENT         = 0x04;
    const FLAG_EXTERNAL_SPEED_FRESH = 0x08;

    // Settings TLV types written to characteristic 53f3c0b6.
    // Firmware mirror: keep these byte values in sync with the Zephyr handler.
    const SETTINGS_TYPE_MASS_KG_X10        = 0x01;
    const SETTINGS_TYPE_COAST_DOWN_REQUEST = 0x03;
    const SETTINGS_TYPE_PRESSURE_CAL_REQUEST = 0x04;

    // Application.Properties keys (must match resources/settings/properties.xml).
    const PROP_TAP_TO_COAST_ENABLED = "tap_to_coast_enabled";
    const PROP_TRIGGER_PRESSURE_CAL = "trigger_pressure_cal";

    // Defaults shown in the pairing UI.
    const DEFAULT_MASS_KG = 80;
}
