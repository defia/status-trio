import CoreBluetooth
import Foundation

/// Which advertisements the nearby battery scanner may open a GATT session with.
///
/// Two routes lead to a connection, and they exist for different devices.
///
/// A peripheral that lists the standard Battery Service (`180F`) in its
/// advertisement is asking to be read: the service is the whole reason to
/// connect, and a device that publishes it in the advertisement is one the
/// standard read can answer for. This is the route the scanner shipped with,
/// and it is the only thing a keyboard or a mouse ever offers.
///
/// An iPhone, an iPad or a Watch never advertises `180F`. Apple's mobile
/// devices broadcast their Continuity payload instead — manufacturer data whose
/// first byte is Apple's company identifier and whose third byte is the message
/// type — and the Battery Service only appears *after* the connection is up.
/// Reading an iOS device therefore starts with recognising that payload, which
/// is what makes the iPhone row work in AirBattery, whose parser this follows.
///
/// Advertisement recognition identifies Apple mobile candidates. A GATT session
/// is separately limited to a UUID whose row is currently visible in the panel.
enum BluetoothLEBatteryAdvertisement {
    /// Apple's Bluetooth SIG company identifier, first on the wire.
    static let appleCompanyIdentifier: UInt8 = 0x4C

    /// The Continuity message types an iOS device broadcasts while nearby.
    ///
    /// `0x10` is Nearby Info and `0x0C` is Handoff; Apple's phones and tablets
    /// send both. The byte after the company identifier is the message length,
    /// so the type is the third byte.
    static let continuityMessageTypes: Set<UInt8> = [0x10, 0x0C]

    /// The offset of the Continuity message type within the manufacturer data.
    private static let continuityMessageTypeOffset = 2

    /// Whether the advertisement offers the standard Battery Service, which is
    /// on its own enough to make a connection worth opening.
    ///
    /// The identifiers are compared case-insensitively because the two sides can
    /// disagree on case: a `CBUUID` built from a string keeps the string's own
    /// spelling, while one an advertisement carries is normalized.
    static func advertisesBatteryService(
        _ serviceUUIDs: [CBUUID]?,
        batteryService: CBUUID
    ) -> Bool {
        guard let serviceUUIDs else { return false }
        return serviceUUIDs.contains {
            $0.uuidString.caseInsensitiveCompare(batteryService.uuidString) == .orderedSame
        }
    }

    /// Whether the payload is an Apple mobile device announcing itself.
    ///
    /// The length is checked before the type byte is read, so a payload that is
    /// only the company identifier — or the identifier and a length, which is
    /// what AirPods send with their own message types — cannot be read past its
    /// end.
    static func isAppleMobileDevice(manufacturerData: Data?) -> Bool {
        guard let manufacturerData,
              manufacturerData.count > continuityMessageTypeOffset else {
            return false
        }
        // The indices are taken from `startIndex` rather than written as 0..2,
        // because a sliced `Data` keeps the offsets of the buffer it came from.
        return manufacturerData[manufacturerData.startIndex] == appleCompanyIdentifier
            && manufacturerData[manufacturerData.startIndex + 1] == 0x00
            && continuityMessageTypes.contains(
                manufacturerData[manufacturerData.startIndex + continuityMessageTypeOffset]
            )
    }

    /// Whether a discovered peripheral is worth a GATT session.
    ///
    /// `name` is the name the system already knows for the peripheral, taken
    /// from the advertisement when it carries one and from CoreBluetooth's cache
    /// otherwise. An absent or blank one is what a stranger's device looks like.
    ///
    /// `allowsAppleMobileDevices` is the user's switch for reading a phone over
    /// the air. An iOS device asks to pair before it answers a read — the prompt
    /// is the device's own, not something the app can answer — so a user who has
    /// not opted into that prompt must not reach the Continuity route at all.
    /// The standard Battery Service route is unaffected: a keyboard or a mouse
    /// advertises `180F` and answers without asking for anything.
    static func isCandidate(
        serviceUUIDs: [CBUUID]?,
        manufacturerData: Data?,
        name: String?,
        batteryService: CBUUID,
        allowsAppleMobileDevices: Bool
    ) -> Bool {
        if advertisesBatteryService(serviceUUIDs, batteryService: batteryService) {
            return true
        }
        guard allowsAppleMobileDevices else { return false }
        guard isAppleMobileDevice(manufacturerData: manufacturerData) else { return false }
        return isKnownAppleMobileDevice(name: name)
    }

    /// Whether the Apple payload came from a device this Mac already knows.
    ///
    /// The Continuity route needs a condition the service route does not: a
    /// name. Every iPhone in radio range broadcasts the payload, and the pairing
    /// prompt the device raises shows the phone's own name — "iPhone", not
    /// whatever the user calls it. Connecting on the payload alone therefore
    /// connected a stranger's phone and raised a prompt the user could neither
    /// answer nor identify (issue `#152`).
    ///
    /// CoreBluetooth only reports a name for a peripheral the system already
    /// knows — one this Mac paired with or has connected to before — so the name
    /// is what keeps this route on the user's own devices. It filters on
    /// identity: macOS withholds the name from a stranger, not the battery.
    static func isKnownAppleMobileDevice(name: String?) -> Bool {
        !(name ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
