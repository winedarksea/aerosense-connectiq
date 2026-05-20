We have a primary goal: receive data from the aerosense device, consisting of humidity, wind speed, wind yaw/angle, activity classification, surface classification, CdA, and grade. Note this is separate from the "cadence hack" (ie outputting CdA scaled to fit 0 to 255 in the cadence sensor profile) for sending data out from the aerosense, which wouldn't need a special data field like this.
A secondary goal of boardcasting speed from the Garmin to the device (for when a dedicated ANT+ speed sensor on the wheel is not available), using either ANT+ or bluetooth with a standard speed profile (ANT+ preferred but not required).
A tertiary goal of being able to set aerosense settings from the Garmin device. For starters users should be able to pass total mass (rider + bike + gear).
Target API level is 5.1.0
References:
https://developer.garmin.com/connect-iq/core-topics/pairing-wireless-devices/ (since 5.1 api level)
https://developer.garmin.com/connect-iq/connect-iq-basics/your-first-app/
https://developer.garmin.com/connect-iq/connect-iq-basics/app-types/#data-fields
