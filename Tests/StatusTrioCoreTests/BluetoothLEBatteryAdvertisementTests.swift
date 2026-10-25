import CoreBluetooth
import Foundation
import Testing
@testable import StatusTrioCore

struct BluetoothLEBatteryAdvertisementTests {
    private let batteryService = CBUUID(string: "180F")

    /// Apple's company identifier and a Continuity message type, as the radio
    /// delivers them: identifier first, then the message length.
    private func appleManufacturerData(messageType: UInt8) -> Data {
        Data([0x4C, 0x00, messageType, 0x01, 0x02])
    }

    @Test func advertisesTheBatteryServiceItselfIsEnoughToBeACandidate() {
        #expect(BluetoothLEBatteryAdvertisement.isCandidate(
            serviceUUIDs: [batteryService],
            manufacturerData: nil,
            name: nil,
            batteryService: batteryService,
            allowsAppleMobileDevices: true
        ))
    }

    @Test func batteryServiceMatchIgnoresCaseAndOtherServices() {
        #expect(BluetoothLEBatteryAdvertisement.advertisesBatteryService(
            [CBUUID(string: "180a"), CBUUID(string: "180f")],
            batteryService: batteryService
        ))
        #expect(!BluetoothLEBatteryAdvertisement.advertisesBatteryService(
            [CBUUID(string: "180A"), CBUUID(string: "1805")],
            batteryService: batteryService
        ))
    }

    @Test func missingServiceListIsNotABatteryAdvertisement() {
        #expect(!BluetoothLEBatteryAdvertisement.advertisesBatteryService(
            nil,
            batteryService: batteryService
        ))
    }

    /// An iPhone does not advertise the Battery Service, so the Continuity
    /// payload plus a name the system knows is the whole signal.
    @Test func knownAppleMobileDeviceIsACandidateWithoutTheBatteryService() {
        for messageType: UInt8 in [0x10, 0x0C] {
            #expect(BluetoothLEBatteryAdvertisement.isCandidate(
                serviceUUIDs: nil,
                manufacturerData: appleManufacturerData(messageType: messageType),
                name: "Ling's iPhone",
                batteryService: batteryService,
            allowsAppleMobileDevices: true
            ))
        }
    }

    /// Names are for display only; an empty name cannot suppress discovery.
    @Test func unnamedAppleBroadcastsRemainCandidates() {
        for name: String? in [nil, "", "   ", "\n"] {
            #expect(BluetoothLEBatteryAdvertisement.isCandidate(
                serviceUUIDs: nil,
                manufacturerData: appleManufacturerData(messageType: 0x10),
                name: name,
                batteryService: batteryService,
            allowsAppleMobileDevices: true
            ))
        }
    }

    /// AirPods send their own Continuity message types, and their battery is
    /// read by the paired-device path rather than this scanner.
    @Test func applePayloadWithAnotherMessageTypeIsNotACandidate() {
        for messageType: UInt8 in [0x07, 0x12, 0x01, 0x0D] {
            #expect(!BluetoothLEBatteryAdvertisement.isCandidate(
                serviceUUIDs: nil,
                manufacturerData: appleManufacturerData(messageType: messageType),
                name: "AirPods",
                batteryService: batteryService,
            allowsAppleMobileDevices: true
            ))
        }
    }

    @Test func anotherVendorsPayloadIsNotACandidate() {
        #expect(!BluetoothLEBatteryAdvertisement.isCandidate(
            serviceUUIDs: nil,
            manufacturerData: Data([0x06, 0x00, 0x10]),
            name: "Some Sensor",
            batteryService: batteryService,
            allowsAppleMobileDevices: true
        ))
    }

    @Test func appleContinuityRequiresTheCompleteCompanyIdentifier() {
        #expect(!BluetoothLEBatteryAdvertisement.isAppleMobileDevice(
            manufacturerData: Data([0x4C, 0x01, 0x10, 0x01])
        ))
    }

    /// A payload that carries no message type — or no payload at all — cannot
    /// be read past its end.
    @Test func shortManufacturerDataIsNotReadPastItsEnd() {
        for payload: Data? in [nil, Data(), Data([0x4C]), Data([0x4C, 0x00])] {
            #expect(!BluetoothLEBatteryAdvertisement.isAppleMobileDevice(manufacturerData: payload))
            #expect(!BluetoothLEBatteryAdvertisement.isCandidate(
                serviceUUIDs: nil,
                manufacturerData: payload,
                name: "Ling's iPhone",
                batteryService: batteryService,
            allowsAppleMobileDevices: true
            ))
        }
    }

    /// A sliced `Data` keeps the offsets of the buffer it came from, so the
    /// offsets have to come from `startIndex` rather than being written as 0..2.
    @Test func readsASlicedPayloadFromItsOwnStartIndex() {
        let framed = Data([0xFF, 0xFF]) + appleManufacturerData(messageType: 0x10)
        let slice = framed.dropFirst(2)

        #expect(slice.startIndex == 2)
        #expect(BluetoothLEBatteryAdvertisement.isAppleMobileDevice(manufacturerData: slice))
    }

    /// The switch that gates reading a phone over the air gates the Continuity
    /// route with it. A device that advertises the Battery Service is still a
    /// candidate — it answers without asking the user anything.
    @Test func appleMobileRouteIsGatedByTheUserSwitch() {
        let phone = appleManufacturerData(messageType: 0x10)
        #expect(!BluetoothLEBatteryAdvertisement.isCandidate(
            serviceUUIDs: nil,
            manufacturerData: phone,
            name: "Ling's iPhone",
            batteryService: batteryService,
            allowsAppleMobileDevices: false
        ))
        #expect(BluetoothLEBatteryAdvertisement.isCandidate(
            serviceUUIDs: [batteryService],
            manufacturerData: nil,
            name: "MX Keys",
            batteryService: batteryService,
            allowsAppleMobileDevices: false
        ))
    }

    @Test func deviceInformationAloneIsNotACandidate() {
        #expect(!BluetoothLEBatteryAdvertisement.isCandidate(
            serviceUUIDs: [CBUUID(string: "180A")],
            manufacturerData: nil,
            name: "MX Keys",
            batteryService: batteryService,
            allowsAppleMobileDevices: true
        ))
    }
}
