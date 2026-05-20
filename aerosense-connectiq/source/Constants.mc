import Toybox.Lang;

module Constants {
    module Keys {
        enum Key {
            PAIRED_SENSOR,
            MASS_KG,
            WHEEL_CIRC_MM
        }
    }

    // Telemetry flag bits (matches firmware src/ble/ble.c fill_telemetry()).
    const FLAG_YAW_VALID            = 0x01;
    const FLAG_PEER_CONNECTED       = 0x02;
    const FLAG_VBUS_PRESENT         = 0x04;
    const FLAG_EXTERNAL_SPEED_FRESH = 0x08;

    // Settings TLV types written to characteristic 53f3c0b6.
    const SETTINGS_TYPE_MASS_KG_X10        = 0x01;
    const SETTINGS_TYPE_WHEEL_CIRC_MM      = 0x02;

    // Defaults shown in the pairing UI.
    const DEFAULT_MASS_KG       = 80;
    const DEFAULT_WHEEL_CIRC_MM = 2100;
}
