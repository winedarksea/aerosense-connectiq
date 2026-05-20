import Toybox.BluetoothLowEnergy;
import Toybox.Lang;

//! Aerosense BLE GATT profile.
//! UUID base: 53f3c0bX-4f7f-4787-8af0-0c9dd053cda0
class ProfileManager {
    public const AEROSENSE_SERVICE        = BluetoothLowEnergy.stringToUuid("53f3c0b1-4f7f-4787-8af0-0c9dd053cda0");
    public const TELEMETRY_CHARACTERISTIC = BluetoothLowEnergy.stringToUuid("53f3c0b2-4f7f-4787-8af0-0c9dd053cda0");
    public const CONTROL_CHARACTERISTIC   = BluetoothLowEnergy.stringToUuid("53f3c0b3-4f7f-4787-8af0-0c9dd053cda0");
    public const SPEED_CHARACTERISTIC     = BluetoothLowEnergy.stringToUuid("53f3c0b4-4f7f-4787-8af0-0c9dd053cda0");
    public const POWER_CHARACTERISTIC     = BluetoothLowEnergy.stringToUuid("53f3c0b5-4f7f-4787-8af0-0c9dd053cda0");
    public const SETTINGS_CHARACTERISTIC  = BluetoothLowEnergy.stringToUuid("53f3c0b6-4f7f-4787-8af0-0c9dd053cda0");

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
