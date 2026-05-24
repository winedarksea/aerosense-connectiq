We have a primary goal: receive data from the aerosense device, consisting of humidity (humidity collected but not shown in data field), wind speed, wind yaw/angle, activity classification, surface classification, CdA, and grade. Note this is separate from the "cadence hack" (ie outputting CdA scaled to fit 0 to 255 in the cadence sensor profile) for sending data out from the aerosense, which wouldn't need a special data field like this.
A secondary goal of boardcasting speed from the Garmin to the device (for when a dedicated ANT+ speed sensor on the wheel is not available). It can reuse the existing BLE connection to the Garmin to write speed into the device.
A tertiary goal of being able to set aerosense settings from the Garmin device. For starters users should be able to pass total mass (rider + bike + gear). Also to trigger static pressure calibration via the settings (so from phone to Garmin to aerosense likely). Coast down may also be enabled by a tap pattern from the Garmin app. Pressure calibration and coast down both carefully gated on the firmware side to only activate on relevant conditions (such as if power meter is connected, it is at zero watts).
When the data field has enough vertical room (Edge 1040 in a 1-up layout), append a row of native metrics (power, heart rate, distance, lap time) below the aero grid using `Activity.Info` to make this a "one stop Time Trial view".
Note this will be using the custom GATT for BLE (not a standard cycling sensor), the CSC cadence hack is for devices that don't have the Garmin ConnectIQ app available.
Target API level is 5.1.0
References:
https://developer.garmin.com/connect-iq/core-topics/pairing-wireless-devices/ (since 5.1 api level)
https://developer.garmin.com/connect-iq/connect-iq-basics/your-first-app/
https://developer.garmin.com/connect-iq/connect-iq-basics/app-types/#data-fields
