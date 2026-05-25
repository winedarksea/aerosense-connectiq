import Toybox.BluetoothLowEnergy;
import Toybox.Lang;

//! Aerosense BLE GATT profile.
//! UUID base: 53f3c0bX-4f7f-4787-8af0-0c9dd053cda0
class ProfileManager {
    // UUID base: 53f3c0bX-4f7f-4787-8af0-0c9dd053cda0
    // Encoded as longToUuid(high, low) matching the Garmin reference sample pattern.
    // high = bytes 0-7 big-endian, low = bytes 8-15 big-endian.
    public const AEROSENSE_SERVICE        = BluetoothLowEnergy.longToUuid(0x53F3C0B14F7F4787l, 0x8AF00C9DD053CDA0l);
    public const TELEMETRY_CHARACTERISTIC = BluetoothLowEnergy.longToUuid(0x53F3C0B24F7F4787l, 0x8AF00C9DD053CDA0l);
    public const CONTROL_CHARACTERISTIC   = BluetoothLowEnergy.longToUuid(0x53F3C0B34F7F4787l, 0x8AF00C9DD053CDA0l);
    public const SPEED_CHARACTERISTIC     = BluetoothLowEnergy.longToUuid(0x53F3C0B44F7F4787l, 0x8AF00C9DD053CDA0l);
    public const POWER_CHARACTERISTIC     = BluetoothLowEnergy.longToUuid(0x53F3C0B54F7F4787l, 0x8AF00C9DD053CDA0l);
    public const SETTINGS_CHARACTERISTIC  = BluetoothLowEnergy.longToUuid(0x53F3C0B64F7F4787l, 0x8AF00C9DD053CDA0l);

    private const _aerosenseProfileDef = {
        :uuid => AEROSENSE_SERVICE,
        :characteristics => [{
            :uuid => TELEMETRY_CHARACTERISTIC,
            :descriptors => [BluetoothLowEnergy.cccdUuid()]
        }, {
            :uuid => CONTROL_CHARACTERISTIC
        }, {
            :uuid => SPEED_CHARACTERISTIC
        }, {
            :uuid => POWER_CHARACTERISTIC
        }, {
            :uuid => SETTINGS_CHARACTERISTIC
        }]
    };

    public function registerProfiles() as Void {
        BluetoothLowEnergy.registerProfile(_aerosenseProfileDef);
    }
}
