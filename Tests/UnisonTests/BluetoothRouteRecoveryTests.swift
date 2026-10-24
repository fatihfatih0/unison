import CoreAudio
import XCTest
@testable import Unison

final class BluetoothRouteRecoveryTests: XCTestCase {
    private let speaker = Output(id: 10, uid: "speaker", name: "MacBook", volume: 0.4, muted: false,
                                 isAggregate: false, transportType: kAudioDeviceTransportTypeBuiltIn)
    private let hdmi = Output(id: 20, uid: "hdmi", name: "HDMI", volume: nil, muted: nil,
                              isAggregate: false, transportType: kAudioDeviceTransportTypeHDMI)
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
        var recovery = BluetoothRouteRecovery(pending: route())
        XCTAssertNil(recovery.update(current: speaker, outputs: [speaker, hdmi, headset]))
        XCTAssertEqual(recovery.update(current: speaker, outputs: [speaker, hdmi]), route())
    }

    func testDelayedCaseDisconnectSurvivesRepeatedFallbackRefreshes() {
        var recovery = BluetoothRouteRecovery(pending: route())
        for _ in 0..<20 {
            XCTAssertNil(recovery.update(current: speaker, outputs: [speaker, hdmi, headset]))
            XCTAssertNotNil(recovery.pending)
        }
        XCTAssertEqual(recovery.update(current: speaker, outputs: [speaker, hdmi]), route())
    }

    func testDisconnectRecoversEvenIfHALStillReportsTheDepartedHeadset() {
        var recovery = BluetoothRouteRecovery(pending: route())
        XCTAssertEqual(recovery.update(current: headset, outputs: [speaker, hdmi]), route())
    }

    func testDisconnectRecoversWithoutWaitingForAValidSystemDefault() {
        var recovery = BluetoothRouteRecovery(pending: route())
        XCTAssertEqual(recovery.update(current: nil, outputs: [speaker, hdmi]), route())
    }

    func testMissingDefaultWaitsOnlyForSavedOutputsToBecomeAvailable() {
        var recovery = BluetoothRouteRecovery(pending: route())
        XCTAssertNil(recovery.update(current: nil, outputs: [speaker]))
        XCTAssertNotNil(recovery.pending)
        XCTAssertEqual(recovery.update(current: nil, outputs: [speaker, hdmi]), route())
    }

    func testSystemFallbackWhileHeadsetRemainsConnectedDoesNotStartGroup() {
        var recovery = BluetoothRouteRecovery(pending: route())
        XCTAssertNil(recovery.update(current: speaker, outputs: [speaker, hdmi, headset]))
        XCTAssertNil(recovery.update(current: speaker, outputs: [speaker, hdmi, headset]))
        XCTAssertNotNil(recovery.pending)
        XCTAssertEqual(recovery.update(current: speaker, outputs: [speaker, hdmi]), route())
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

    func testBriefHeadsetReconnectKeepsReturnArmed() {
        var recovery = BluetoothRouteRecovery(pending: route())
        XCTAssertNil(recovery.update(current: speaker, outputs: [speaker, hdmi, headset]))
        XCTAssertNil(recovery.update(current: headset, outputs: [speaker, hdmi, headset]))
        XCTAssertNil(recovery.update(current: speaker, outputs: [speaker, hdmi, headset]))
        XCTAssertNotNil(recovery.pending)
        XCTAssertEqual(recovery.update(current: speaker, outputs: [speaker, hdmi]), route())
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

    func testHeadsetWithoutPreviousGroupReturnsToSpeakerAndHDMI() throws {
        let saved = try XCTUnwrap(BluetoothAudioRoute.automatic(bluetoothUID: headset.uid, outputs: [speaker, hdmi, headset],
                                                              volume: speaker.volume!, muted: false))
        var recovery = BluetoothRouteRecovery()
        recovery.remember(saved)
        XCTAssertNil(recovery.update(current: headset, outputs: [speaker, hdmi, headset]))
        let restored = try XCTUnwrap(recovery.update(current: speaker, outputs: [speaker, hdmi]))
        XCTAssertEqual(restored.outputUIDs, [speaker.uid, hdmi.uid])
        XCTAssertEqual(restored.mode, .automatic)
        XCTAssertEqual(restored.volume, speaker.volume)
        XCTAssertNil(recovery.pending)
        XCTAssertNil(recovery.update(current: speaker, outputs: [speaker, hdmi]))
    }

    func testAutomaticReturnIncludesHDMIConnectedWhileHeadsetWasInUse() throws {
        let saved = try XCTUnwrap(BluetoothAudioRoute.automatic(bluetoothUID: headset.uid, outputs: [speaker, headset],
                                                              volume: 0.3, muted: true))
        var recovery = BluetoothRouteRecovery(pending: saved)
        let restored = try XCTUnwrap(recovery.update(current: speaker, outputs: [speaker, hdmi]))
        XCTAssertEqual(restored.outputUIDs, [speaker.uid, hdmi.uid])
        XCTAssertEqual(restored.volume, 0.3)
        XCTAssertTrue(restored.muted)
    }

    func testAutomaticReturnUsesOnlyNativeSpeakerWhenHDMIWasUnplugged() throws {
        let saved = try XCTUnwrap(BluetoothAudioRoute.automatic(bluetoothUID: headset.uid, outputs: [speaker, hdmi, headset],
                                                              volume: 0.3, muted: false))
        var recovery = BluetoothRouteRecovery(pending: saved)
        let restored = try XCTUnwrap(recovery.update(current: speaker, outputs: [speaker]))
        XCTAssertEqual(restored.outputUIDs, [speaker.uid])
        XCTAssertNil(recovery.pending)
    }

    func testAutomaticReturnWaitsForHeadsetRemovalDespiteEarlySpeakerFallback() throws {
        let saved = try XCTUnwrap(BluetoothAudioRoute.automatic(bluetoothUID: headset.uid, outputs: [speaker, hdmi, headset],
                                                              volume: 0.3, muted: false))
        var recovery = BluetoothRouteRecovery(pending: saved)
        XCTAssertNil(recovery.update(current: speaker, outputs: [speaker, hdmi, headset]))
        XCTAssertEqual(recovery.update(current: speaker, outputs: [speaker, hdmi])?.outputUIDs,
                       [speaker.uid, hdmi.uid])
    }

    func testAutomaticReturnDoesNotOverrideSystemSwitchWhileHeadsetStaysConnected() throws {
        let saved = try XCTUnwrap(BluetoothAudioRoute.automatic(bluetoothUID: headset.uid, outputs: [speaker, hdmi, headset],
                                                              volume: 0.3, muted: false))
        var recovery = BluetoothRouteRecovery(pending: saved)
        for _ in 0..<20 {
            XCTAssertNil(recovery.update(current: hdmi, outputs: [speaker, hdmi, headset]))
        }
        XCTAssertNotNil(recovery.pending)
        XCTAssertEqual(recovery.update(current: speaker, outputs: [speaker, hdmi]), saved)
    }

    func testHALFallbackChangesBeforeHeadsetRemovalDoNotCancelReturn() {
        let controller = Output(id: 60, uid: "org.unison.output", name: "Unison", volume: 0.8, muted: false, isAggregate: false)
        var recovery = BluetoothRouteRecovery(pending: route())
        XCTAssertNil(recovery.update(current: controller, outputs: [speaker, hdmi, headset]))
        XCTAssertNil(recovery.update(current: speaker, outputs: [speaker, hdmi, headset]))
        XCTAssertEqual(recovery.update(current: speaker, outputs: [speaker, hdmi]), route())
    }

    func testAutomaticSpeakerReturnDoesNotNeedAValidSystemDefault() throws {
        let saved = try XCTUnwrap(BluetoothAudioRoute.automatic(bluetoothUID: headset.uid, outputs: [speaker, headset],
                                                              volume: 0.3, muted: false))
        var recovery = BluetoothRouteRecovery(pending: saved)
        XCTAssertEqual(recovery.update(current: nil, outputs: [speaker]), saved)
        XCTAssertNil(recovery.pending)
    }

    func testAutomaticReturnSurvivesRestartAndResolvesLiveDisplayUIDs() throws {
        let saved = try XCTUnwrap(BluetoothAudioRoute.automatic(bluetoothUID: headset.uid, outputs: [speaker, headset],
                                                              volume: 0.3, muted: false))
        let decoded = try JSONDecoder().decode(BluetoothAudioRoute.self, from: JSONEncoder().encode(saved))
        var recovery = BluetoothRouteRecovery(pending: decoded)
        XCTAssertEqual(recovery.update(current: speaker, outputs: [speaker, hdmi])?.outputUIDs, [speaker.uid, hdmi.uid])
    }

    func testAutomaticReturnIncludesDisplayPortAudioButExcludesUnrelatedOutputs() throws {
        let display = Output(id: 40, uid: "display", name: "USB-C Monitor", volume: nil, muted: nil,
                             isAggregate: false, transportType: kAudioDeviceTransportTypeDisplayPort)
        let usb = Output(id: 50, uid: "usb", name: "USB Speakers", volume: 0.5, muted: false,
                         isAggregate: false, transportType: kAudioDeviceTransportTypeUSB)
        let jack = Output(id: 60, uid: "BuiltInHeadphoneDevice", name: "External Headphones", volume: 0.5, muted: false,
                          isAggregate: false, transportType: kAudioDeviceTransportTypeBuiltIn)
        let aggregate = Output(id: 70, uid: "aggregate", name: "Group", volume: nil, muted: nil,
                               isAggregate: true, transportType: kAudioDeviceTransportTypeHDMI)
        let saved = try XCTUnwrap(BluetoothAudioRoute.automatic(bluetoothUID: headset.uid,
                                                              outputs: [jack, aggregate, speaker, hdmi, display, usb, headset],
                                                              volume: 0.3, muted: false))
        XCTAssertEqual(saved.outputUIDs, [speaker.uid, hdmi.uid, display.uid])
        XCTAssertNil(BluetoothAudioRoute.automatic(bluetoothUID: headset.uid, outputs: [jack, hdmi, usb, headset],
                                                  volume: 0.3, muted: false))
    }

    func testAutomaticFallbackCannotReplacePreviouslyRememberedGroup() throws {
        let saved = route(mode: .group)
        var recovery = BluetoothRouteRecovery(pending: saved)
        let automatic = try XCTUnwrap(BluetoothAudioRoute.automatic(bluetoothUID: headset.uid, outputs: [speaker, hdmi],
                                                                  volume: 0.6, muted: false))
        recovery.remember(automatic)
        XCTAssertEqual(recovery.update(current: speaker, outputs: [speaker, hdmi]), saved)
    }

    func testPreviouslyHDMIOnlySoftwareRouteReturnsWithMacSpeakerToo() throws {
        let saved = BluetoothAudioRoute(bluetoothUID: headset.uid, outputUIDs: [hdmi.uid], mode: .software,
                                        volume: 0.35, muted: false)
        var recovery = BluetoothRouteRecovery(pending: saved)
        let restored = try XCTUnwrap(recovery.update(current: speaker, outputs: [speaker, hdmi]))
        XCTAssertEqual(restored.outputUIDs, [speaker.uid, hdmi.uid])
        XCTAssertEqual(restored.mode, .software)
        XCTAssertEqual(restored.volume, saved.volume)
    }

    func testSavedGroupUsesCurrentlyConnectedHDMIInsteadOfWaitingForOldDisplay() throws {
        let replacement = Output(id: 40, uid: "replacement-hdmi", name: "New Monitor", volume: nil, muted: nil,
                                 isAggregate: false, transportType: kAudioDeviceTransportTypeHDMI)
        var recovery = BluetoothRouteRecovery(pending: route(mode: .group))
        let restored = try XCTUnwrap(recovery.update(current: speaker, outputs: [speaker, replacement]))
        XCTAssertEqual(restored.outputUIDs, [speaker.uid, replacement.uid])
        XCTAssertEqual(restored.mode, .group)
        XCTAssertEqual(restored.volume, route().volume)
        XCTAssertTrue(restored.muted)
    }
}
