import CoreAudio
import XCTest
@testable import Unison

final class BluetoothRouteRecoveryTests: XCTestCase {
    private let speaker = Output(id: 10, uid: "speaker", name: "MacBook", volume: 0.4, muted: false, isAggregate: false)
    private let hdmi = Output(id: 20, uid: "hdmi", name: "HDMI", volume: nil, muted: nil, isAggregate: false)
    private let headset = Output(id: 30, uid: "headset", name: "Headset", volume: 0.8, muted: false,
                                 isAggregate: false, transportType: kAudioDeviceTransportTypeBluetooth)

    private func route(mode: BluetoothAudioRoute.Mode = .software) -> BluetoothAudioRoute {
        BluetoothAudioRoute(bluetoothUID: headset.uid, outputUIDs: [speaker.uid, hdmi.uid], mode: mode, volume: 0.35, muted: true)
    }

    func testHeadsetDisconnectRestoresGroupAndItsLevelExactlyOnce() {
        let saved = route()
        var recovery = BluetoothRouteRecovery(pending: saved)
        XCTAssertNil(recovery.update(current: headset, outputs: [speaker, hdmi, headset]))
        XCTAssertEqual(recovery.update(current: speaker, outputs: [speaker, hdmi]), saved)
        XCTAssertNil(recovery.pending)
        XCTAssertNil(recovery.update(current: speaker, outputs: [speaker, hdmi]))
    }

    func testFallbackNotificationBeforeDeviceRemovalStillRestores() {
        let now = ContinuousClock.now
        var recovery = BluetoothRouteRecovery(pending: route())
        XCTAssertNil(recovery.update(current: speaker, outputs: [speaker, hdmi, headset], now: now))
        XCTAssertEqual(recovery.update(current: speaker, outputs: [speaker, hdmi], now: now.advanced(by: .seconds(1))), route())
    }

    func testDeviceRemovalBeforeDefaultNotificationWaitsForValidOutput() {
        var recovery = BluetoothRouteRecovery(pending: route())
        XCTAssertNil(recovery.update(current: nil, outputs: [speaker, hdmi]))
        XCTAssertNotNil(recovery.pending)
        XCTAssertEqual(recovery.update(current: speaker, outputs: [speaker, hdmi]), route())
    }

    func testManualSystemRouteChangeWhileHeadsetRemainsConnectedCancelsReturn() {
        let now = ContinuousClock.now
        var recovery = BluetoothRouteRecovery(pending: route())
        XCTAssertNil(recovery.update(current: speaker, outputs: [speaker, hdmi, headset], now: now))
        XCTAssertNil(recovery.update(current: speaker, outputs: [speaker, hdmi, headset], now: now.advanced(by: .seconds(3))))
        XCTAssertNil(recovery.pending)
        XCTAssertNil(recovery.update(current: speaker, outputs: [speaker, hdmi]))
    }

    func testMissingGroupMemberWaitsForReconnectWithoutChoosingDifferentOutputs() {
        var recovery = BluetoothRouteRecovery(pending: route(mode: .group))
        XCTAssertNil(recovery.update(current: speaker, outputs: [speaker]))
        XCTAssertNotNil(recovery.pending)
        XCTAssertEqual(recovery.update(current: speaker, outputs: [speaker, hdmi]), route(mode: .group))
    }

    func testExplicitRouteChangeWhileWaitingForGroupCancelsReturn() {
        var recovery = BluetoothRouteRecovery(pending: route())
        XCTAssertNil(recovery.update(current: speaker, outputs: [speaker]))
        XCTAssertNil(recovery.update(current: hdmi, outputs: [speaker, hdmi]))
        XCTAssertNil(recovery.pending)
    }

    func testSwitchingBluetoothHeadsetsKeepsOriginalGroupUntilLastHeadsetDisconnects() {
        let other = Output(id: 40, uid: "other-headset", name: "Other", volume: 0.7, muted: false,
                           isAggregate: false, transportType: kAudioDeviceTransportTypeBluetoothLE)
        var recovery = BluetoothRouteRecovery(pending: route())
        XCTAssertNil(recovery.update(current: other, outputs: [speaker, hdmi, other]))
        XCTAssertEqual(recovery.pending?.bluetoothUID, other.uid)
        XCTAssertEqual(recovery.update(current: speaker, outputs: [speaker, hdmi])?.outputUIDs, route().outputUIDs)
    }

    func testBriefHeadsetReconnectResetsDepartureGracePeriod() {
        let now = ContinuousClock.now
        var recovery = BluetoothRouteRecovery(pending: route())
        XCTAssertNil(recovery.update(current: speaker, outputs: [speaker, hdmi, headset], now: now))
        XCTAssertNil(recovery.update(current: headset, outputs: [speaker, hdmi, headset], now: now.advanced(by: .seconds(2))))
        XCTAssertNil(recovery.update(current: speaker, outputs: [speaker, hdmi, headset], now: now.advanced(by: .seconds(4))))
        XCTAssertNotNil(recovery.pending)
        XCTAssertEqual(recovery.update(current: speaker, outputs: [speaker, hdmi], now: now.advanced(by: .seconds(5))), route())
    }

    func testManualSelectionOrStopCancelsPendingReturn() {
        var recovery = BluetoothRouteRecovery(pending: route())
        recovery.cancel()
        XCTAssertNil(recovery.update(current: speaker, outputs: [speaker, hdmi]))
    }

    func testHeadsetAlreadyInConfiguredGroupIsNotATemporaryRoute() {
        var recovery = BluetoothRouteRecovery()
        recovery.remember(BluetoothAudioRoute(bluetoothUID: headset.uid, outputUIDs: [speaker.uid, headset.uid],
                                             mode: .software, volume: 0.4, muted: false))
        XCTAssertNil(recovery.pending)
    }

    func testHeadsetSelectionCannotOverwriteRememberedGroup() {
        var recovery = BluetoothRouteRecovery(pending: route())
        recovery.remember(BluetoothAudioRoute(bluetoothUID: headset.uid, outputUIDs: [headset.uid],
                                             mode: .software, volume: 0.8, muted: false))
        XCTAssertEqual(recovery.pending, route())
    }

    func testPendingReturnSurvivesAppRestartAndUsesDeviceUIDs() throws {
        let saved = route(mode: .group)
        let decoded = try JSONDecoder().decode(BluetoothAudioRoute.self, from: JSONEncoder().encode(saved))
        let reconnectedSpeaker = Output(id: 110, uid: speaker.uid, name: speaker.name, volume: 0.9, muted: false, isAggregate: false)
        let reconnectedHDMI = Output(id: 120, uid: hdmi.uid, name: hdmi.name, volume: nil, muted: nil, isAggregate: false)
        var recovery = BluetoothRouteRecovery(pending: decoded)
        XCTAssertEqual(recovery.update(current: reconnectedSpeaker, outputs: [reconnectedSpeaker, reconnectedHDMI]), saved)
    }

    func testBluetoothTransportDetectionDoesNotDependOnDeviceName() {
        XCTAssertTrue(headset.isBluetooth)
        XCTAssertFalse(speaker.isBluetooth)
        XCTAssertFalse(hdmi.isBluetooth)
    }

    func testMacOSMultiOutputDeviceIsRememberedAndMustExistBeforeReturn() {
        let aggregate = Output(id: 50, uid: "multi-output", name: "Çok Çıkışlı Aygıt", volume: nil, muted: nil, isAggregate: true)
        let saved = BluetoothAudioRoute(bluetoothUID: headset.uid, outputUIDs: [speaker.uid, hdmi.uid],
                                        mode: .device, volume: 0.4, muted: false, deviceUID: aggregate.uid)
        var recovery = BluetoothRouteRecovery(pending: saved)
        XCTAssertNil(recovery.update(current: speaker, outputs: [speaker, hdmi]))
        XCTAssertEqual(recovery.update(current: speaker, outputs: [speaker, hdmi, aggregate]), saved)
    }

    func testUnisonVirtualOutputCanBeTheSystemFallbackAfterDisconnect() {
        let controller = Output(id: 60, uid: "org.unison.output", name: "Unison", volume: 0.8, muted: false, isAggregate: false)
        var recovery = BluetoothRouteRecovery(pending: route())
        XCTAssertEqual(recovery.update(current: controller, outputs: [speaker, hdmi]), route())
    }
}
