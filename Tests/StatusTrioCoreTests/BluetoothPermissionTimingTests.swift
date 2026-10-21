import Foundation
import XCTest
@testable import StatusTrioCore

@MainActor
final class BluetoothPermissionTimingTests: XCTestCase {
    func testOpeningPopoverExposesBluetoothAuthorizationWithoutStartingMonitor() {
        let stateMonitor = BluetoothStateMonitorSpy(authorization: .notDetermined)
        let bluetoothController = BluetoothDeviceController(
            stateMonitor: stateMonitor,
            notificationCenter: NotificationCenter(),
            workspaceNotificationCenter: NotificationCenter()
        )
        let store = SystemStatusStore(
            batteryMonitor: EmptyBatteryMonitorForBluetoothTiming(),
            wifiMonitor: EmptyWiFiMonitorForBluetoothTiming(),
            volumeMonitor: EmptyVolumeMonitorForBluetoothTiming(),
            bluetoothDevices: bluetoothController
        )

        store.setPopoverVisible(true)

        XCTAssertEqual(bluetoothController.availability, .authorizationNotDetermined)
        XCTAssertEqual(stateMonitor.startCount, 0)
    }

    func testNearbyClaimOnUnauthorizedPopoverDoesNotStartBluetoothOrPrompt() {
        let stateMonitor = BluetoothStateMonitorSpy(authorization: .notDetermined)
        let scanner = NearbyBatteryScannerSpy()
        let bluetoothController = BluetoothDeviceController(
            stateMonitor: stateMonitor,
            notificationCenter: NotificationCenter(),
            workspaceNotificationCenter: NotificationCenter(),
            nearbyBatteryScanner: scanner
        )

        bluetoothController.configureNearbyBLEDevices(enabled: true, knownIDs: [], hiddenIDs: [])
        bluetoothController.requestNearbyBLEDiscovery("nearby-test")
        bluetoothController.holdVisibleSurface(BluetoothDeviceController.popoverSurfaceToken)
        bluetoothController.prepareForPresentation()

        XCTAssertEqual(stateMonitor.startCount, 0)
        XCTAssertEqual(scanner.startCount, 0)
        XCTAssertEqual(bluetoothController.availability, .authorizationNotDetermined)
    }

    func testRequestingBluetoothAuthorizationStartsStateMonitor() {
        let stateMonitor = BluetoothStateMonitorSpy(authorization: .notDetermined)
        let bluetoothController = BluetoothDeviceController(
            stateMonitor: stateMonitor,
            notificationCenter: NotificationCenter(),
            workspaceNotificationCenter: NotificationCenter()
        )
        let store = SystemStatusStore(
            batteryMonitor: EmptyBatteryMonitorForBluetoothTiming(),
            wifiMonitor: EmptyWiFiMonitorForBluetoothTiming(),
            volumeMonitor: EmptyVolumeMonitorForBluetoothTiming(),
            bluetoothDevices: bluetoothController
        )

        store.requestBluetoothAuthorization()

        XCTAssertEqual(stateMonitor.startCount, 1)
    }

    func testBluetoothSettingControlsStateMonitorLifecycle() {
        let stateMonitor = BluetoothStateMonitorSpy(authorization: .notDetermined)
        let bluetoothController = BluetoothDeviceController(
            stateMonitor: stateMonitor,
            notificationCenter: NotificationCenter(),
            workspaceNotificationCenter: NotificationCenter()
        )
        let store = SystemStatusStore(
            batteryMonitor: EmptyBatteryMonitorForBluetoothTiming(),
            wifiMonitor: EmptyWiFiMonitorForBluetoothTiming(),
            volumeMonitor: EmptyVolumeMonitorForBluetoothTiming(),
            bluetoothDevices: bluetoothController
        )

        store.setBluetoothEnabled(true)
        XCTAssertEqual(stateMonitor.startCount, 1)

        store.setBluetoothEnabled(false)
        XCTAssertEqual(stateMonitor.stopCount, 1)
    }

    func testExplicitlyEnabledBluetoothMonitorSurvivesPopupClose() {
        let stateMonitor = BluetoothStateMonitorSpy(authorization: .notDetermined)
        let bluetoothController = BluetoothDeviceController(
            stateMonitor: stateMonitor,
            notificationCenter: NotificationCenter(),
            workspaceNotificationCenter: NotificationCenter()
        )
        let store = SystemStatusStore(
            batteryMonitor: EmptyBatteryMonitorForBluetoothTiming(),
            wifiMonitor: EmptyWiFiMonitorForBluetoothTiming(),
            volumeMonitor: EmptyVolumeMonitorForBluetoothTiming(),
            bluetoothDevices: bluetoothController
        )

        store.setBluetoothEnabled(true)
        XCTAssertEqual(stateMonitor.startCount, 1)

        store.setPopoverVisible(true)
        store.setPopoverVisible(false)
        store.closePopoverDetails()

        XCTAssertEqual(stateMonitor.stopCount, 0)
        XCTAssertFalse(store.hasOpenPopoverPanel)

        store.setBluetoothEnabled(false)
        XCTAssertEqual(stateMonitor.stopCount, 1)
    }

    /// An authorized app has nothing left to ask for, so opening the popover
    /// temporarily starts monitoring to refresh device names. Closing the
    /// popover releases that temporary activation.
    func testPopoverOnlyBluetoothActivationStopsWhenPopoverCloses() {
        let stateMonitor = BluetoothStateMonitorSpy(authorization: .allowed)
        stateMonitor.stateOnStart = .poweredOn
        let bluetoothController = BluetoothDeviceController(
            stateMonitor: stateMonitor,
            notificationCenter: NotificationCenter(),
            workspaceNotificationCenter: NotificationCenter()
        )
        let store = SystemStatusStore(
            batteryMonitor: EmptyBatteryMonitorForBluetoothTiming(),
            wifiMonitor: EmptyWiFiMonitorForBluetoothTiming(),
            volumeMonitor: EmptyVolumeMonitorForBluetoothTiming(),
            bluetoothDevices: bluetoothController
        )

        store.setPopoverVisible(true)
        XCTAssertEqual(stateMonitor.startCount, 1)
        XCTAssertTrue(bluetoothController.isActive)

        store.setPopoverVisible(false)
        XCTAssertEqual(stateMonitor.stopCount, 1)
        XCTAssertFalse(bluetoothController.isActive)
    }

    /// Starting the monitor reports an already-powered-on adapter and starts a
    /// read. That opening must not queue a second completed read.
    func testOrdinaryAuthorizedPopoverOpeningCompletesOneBluetoothRead() async {
        let stateMonitor = BluetoothStateMonitorSpy(authorization: .allowed)
        stateMonitor.stateOnStart = .poweredOn
        let reader = ImmediateCountingBluetoothReader()
        let bluetoothController = BluetoothDeviceController(
            worker: reader,
            stateMonitor: stateMonitor,
            notificationCenter: NotificationCenter(),
            workspaceNotificationCenter: NotificationCenter()
        )
        let store = SystemStatusStore(
            batteryMonitor: EmptyBatteryMonitorForBluetoothTiming(),
            wifiMonitor: EmptyWiFiMonitorForBluetoothTiming(),
            volumeMonitor: EmptyVolumeMonitorForBluetoothTiming(),
            bluetoothDevices: bluetoothController
        )

        store.setPopoverVisible(true)
        await waitUntil { bluetoothController.devices.map(\.id) == ["opening-read"] }

        XCTAssertEqual(reader.completedReadCount, 1)
        store.setPopoverVisible(false)
        store.stop()
    }

    /// An already active Settings-owned monitor does not send another state
    /// callback on opening, so the popover must request one refresh itself.
    func testPopoverOpeningRefreshesAlreadyActiveBluetoothMonitorOnce() async {
        let stateMonitor = BluetoothStateMonitorSpy(authorization: .allowed)
        stateMonitor.stateOnStart = .poweredOn
        let reader = ImmediateCountingBluetoothReader()
        let bluetoothController = BluetoothDeviceController(
            worker: reader,
            stateMonitor: stateMonitor,
            notificationCenter: NotificationCenter(),
            workspaceNotificationCenter: NotificationCenter()
        )
        let store = SystemStatusStore(
            batteryMonitor: EmptyBatteryMonitorForBluetoothTiming(),
            wifiMonitor: EmptyWiFiMonitorForBluetoothTiming(),
            volumeMonitor: EmptyVolumeMonitorForBluetoothTiming(),
            bluetoothDevices: bluetoothController
        )

        store.setBluetoothEnabled(true)
        stateMonitor.emit(authorization: .allowed, managerState: .poweredOn)
        await waitUntil { bluetoothController.devices.map(\.id) == ["opening-read"] }
        reader.resetCompletedReadCount()

        store.setPopoverVisible(true)
        await waitUntil { reader.completedReadCount == 1 }

        XCTAssertEqual(reader.completedReadCount, 1)
        store.setPopoverVisible(false)
        store.setBluetoothEnabled(false)
        store.stop()
    }

    /// Settings' Bluetooth section owns the shared controller only while its
    /// page is visible. The popover still needs one fresh read and must leave
    /// that existing activation alive.
    func testPopoverRefreshesControllerWithVisibleSettingsDemand() async {
        let suiteName = "BluetoothPermissionTiming.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let stateMonitor = BluetoothStateMonitorSpy(authorization: .allowed)
        stateMonitor.stateOnStart = .poweredOn
        let reader = ImmediateCountingBluetoothReader()
        let bluetoothController = BluetoothDeviceController(
            worker: reader,
            stateMonitor: stateMonitor,
            notificationCenter: NotificationCenter(),
            workspaceNotificationCenter: NotificationCenter()
        )
        let store = SystemStatusStore(
            batteryMonitor: EmptyBatteryMonitorForBluetoothTiming(),
            wifiMonitor: EmptyWiFiMonitorForBluetoothTiming(),
            volumeMonitor: EmptyVolumeMonitorForBluetoothTiming(),
            bluetoothDevices: bluetoothController
        )
        let settings = SettingsStore(defaults: defaults)
        settings.setPopupSection(.bluetooth, enabled: true)
        store.bindBluetoothSettings(settings)

        store.start()
        store.setBluetoothSettingsVisible(true)
        await waitUntil { bluetoothController.devices.map(\.id) == ["opening-read"] }
        reader.resetCompletedReadCount()

        store.setPopoverVisible(true)

        XCTAssertEqual(reader.completedReadCount, 1)
        store.setPopoverVisible(false)
        XCTAssertTrue(bluetoothController.isActive, "popover close must not stop the existing Settings activation")
        store.setBluetoothSettingsVisible(false)
        XCTAssertFalse(bluetoothController.isActive)
        store.stop()
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: () -> Bool
    ) async {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline {
            await Task.yield()
        }
        XCTAssertTrue(condition(), "Timed out waiting for the Bluetooth read result")
    }

    /// Permission is only ever requested by the user's tap, never by the
    /// popover appearing.
    func testOpeningThePopoverKeepsUnauthorizedBluetoothIdle() {
        let expected: [(BluetoothAuthorizationStatus, BluetoothAvailability)] = [
            (.denied, .authorizationDenied),
            (.restricted, .authorizationRestricted)
        ]
        for (authorization, availability) in expected {
            let stateMonitor = BluetoothStateMonitorSpy(authorization: authorization)
            let bluetoothController = BluetoothDeviceController(
                stateMonitor: stateMonitor,
                notificationCenter: NotificationCenter(),
                workspaceNotificationCenter: NotificationCenter()
            )
            let store = SystemStatusStore(
                batteryMonitor: EmptyBatteryMonitorForBluetoothTiming(),
                wifiMonitor: EmptyWiFiMonitorForBluetoothTiming(),
                volumeMonitor: EmptyVolumeMonitorForBluetoothTiming(),
                bluetoothDevices: bluetoothController
            )

            store.setPopoverVisible(true)

            XCTAssertEqual(stateMonitor.startCount, 0)
            XCTAssertFalse(bluetoothController.isActive)
            XCTAssertEqual(bluetoothController.availability, availability)
            store.stop()
        }
    }

    /// Holding a surface only allows polling; it never starts the state monitor,
    /// so the row cannot raise the permission prompt on its own.
    func testHoldingASurfaceDoesNotStartTheStateMonitor() {
        let stateMonitor = BluetoothStateMonitorSpy(authorization: .notDetermined)
        let bluetoothController = BluetoothDeviceController(
            stateMonitor: stateMonitor,
            notificationCenter: NotificationCenter(),
            workspaceNotificationCenter: NotificationCenter()
        )

        bluetoothController.holdVisibleSurface("bluetooth.summary")

        XCTAssertEqual(stateMonitor.startCount, 0)
        XCTAssertFalse(bluetoothController.isActive)
        XCTAssertFalse(bluetoothController.isSafetyNetPolling)
    }

    /// The popover is what holds the Bluetooth surface, and closing it must stop
    /// the poll and any state monitor started only for that popover.
    func testClosingThePopoverStopsTheSafetyNetPoll() {
        let stateMonitor = BluetoothStateMonitorSpy(authorization: .allowed)
        let bluetoothController = BluetoothDeviceController(
            worker: PermissionTimingBluetoothReader(),
            stateMonitor: stateMonitor,
            notificationCenter: NotificationCenter(),
            workspaceNotificationCenter: NotificationCenter()
        )
        let store = SystemStatusStore(
            batteryMonitor: EmptyBatteryMonitorForBluetoothTiming(),
            wifiMonitor: EmptyWiFiMonitorForBluetoothTiming(),
            volumeMonitor: EmptyVolumeMonitorForBluetoothTiming(),
            bluetoothDevices: bluetoothController
        )

        store.setPopoverVisible(true)
        XCTAssertTrue(bluetoothController.hasVisibleSurface)

        // The adapter reports ready: the poll may now run, and it is the surface
        // claim that allows it.
        stateMonitor.emit(authorization: .allowed, managerState: .poweredOn)
        XCTAssertTrue(bluetoothController.isSafetyNetPolling)

        store.setPopoverVisible(false)
        XCTAssertFalse(bluetoothController.hasVisibleSurface)
        XCTAssertFalse(bluetoothController.isSafetyNetPolling)
        XCTAssertEqual(stateMonitor.stopCount, 1)

        store.setPopoverVisible(true)
        XCTAssertEqual(stateMonitor.startCount, 2)
        stateMonitor.emit(authorization: .allowed, managerState: .poweredOn)
        XCTAssertTrue(bluetoothController.isSafetyNetPolling)
        store.setPopoverVisible(false)
        XCTAssertFalse(bluetoothController.hasVisibleSurface)
        XCTAssertFalse(bluetoothController.isSafetyNetPolling)
        XCTAssertEqual(stateMonitor.stopCount, 2)
    }
}

@MainActor
private final class BluetoothStateMonitorSpy: BluetoothStateMonitoring {
    var onStateChange: ((BluetoothAuthorizationStatus, BluetoothManagerState) -> Void)?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    let authorization: BluetoothAuthorizationStatus
    var stateOnStart: BluetoothManagerState = .unknown

    init(authorization: BluetoothAuthorizationStatus = .notDetermined) {
        self.authorization = authorization
    }

    func start() {
        startCount += 1
        if stateOnStart != .unknown {
            emit(authorization: authorization, managerState: stateOnStart)
        }
    }

    func stop() {
        stopCount += 1
    }

    func emit(authorization: BluetoothAuthorizationStatus, managerState: BluetoothManagerState) {
        onStateChange?(authorization, managerState)
    }
}

/// The default worker runs `/usr/sbin/system_profiler`; a unit test that makes
/// the adapter report ready must not.
private final class ImmediateCountingBluetoothReader: BluetoothPairedDeviceReading {
    private let lock = NSLock()
    private var completedCount = 0

    var completedReadCount: Int { lock.withLock { completedCount } }

    func resetCompletedReadCount() {
        lock.withLock { completedCount = 0 }
    }

    func read(completion: @escaping @Sendable (BluetoothWorkerResult) -> Void) {
        lock.withLock { completedCount += 1 }
        completion(.success([
            BluetoothDevice(id: "opening-read", name: "Test Device", kind: .audio, isConnected: true)
        ]))
    }
}

private final class PermissionTimingBluetoothReader: BluetoothPairedDeviceReading {
    func read(completion: @escaping @Sendable (BluetoothWorkerResult) -> Void) {
        completion(.success([]))
    }
}

@MainActor
private final class EmptyBatteryMonitorForBluetoothTiming: BatteryMonitoring {
    let updates = AsyncStream<BatteryStatus> { continuation in
        continuation.finish()
    }

    func start() {}
    func stop() {}
    func refresh() {}
    func recover() {}
}

@MainActor
private final class EmptyWiFiMonitorForBluetoothTiming: WiFiMonitoring {
    let updates = AsyncStream<WiFiStatus> { continuation in
        continuation.finish()
    }

    func start() {}
    func stop() {}
    func refresh() {}
    func recover() {}
    func requestNameAccess() -> WiFiNameAccessRequestResult { .notNeeded }
}

@MainActor
private final class EmptyVolumeMonitorForBluetoothTiming: VolumeMonitoring {
    let updates = AsyncStream<VolumeStatus> { continuation in
        continuation.finish()
    }

    func start() {}
    func stop() {}
    func refresh() {}
    func recover() {}
}
