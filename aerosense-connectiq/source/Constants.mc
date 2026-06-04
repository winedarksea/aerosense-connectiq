import Toybox.Lang;

module Constants {
    module Keys {
        enum Key {
            PAIRED_SENSOR,
            FIELD_VIEWED
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
    const SETTINGS_TYPE_PRESSURE_CAL_REQUEST = 0x04;

    // Application.Properties keys (must match resources/settings/properties.xml).
    const PROP_MASS_KG = "mass_kg";
    const PROP_TRIGGER_PRESSURE_CAL = "trigger_pressure_cal";
    // Diagnostic on-screen HUD; ships off. Reveals BLE subscription/notify
    // internals on hardware where System.println is not accessible.
    const PROP_DEBUG_HUD = "debug_hud";

    // Native sensor metadata. Garmin's SensorInfo supports these fields for
    // stable sensor identification in the system sensor list.
    const SENSOR_MANUFACTURER_ID = 0xAE70;
    const SENSOR_DEFAULT_PART_NUMBER = 0xAE00;
    const SENSOR_SOFTWARE_VERSION = 1;

    // BLE advertisement defaults. Firmware advertises the custom-service
    // identity as "Aero Custom XXXX" (XXXX = last two bytes of the BLE
    // address). The "Aero CSC XXXX" identity is consumed by Garmin's native
    // cycling cadence support and intentionally not matched here.
    const DEFAULT_DEVICE_NAME = "Aero Custom";
}
