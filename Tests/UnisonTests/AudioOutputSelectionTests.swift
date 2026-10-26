import CoreAudio
import XCTest
@testable import Unison

final class AudioOutputSelectionTests: XCTestCase {
    private let speaker = Output(id: 10, uid: "speaker", name: "MacBook", volume: 0.4, muted: false, isAggregate: false)
    private let headset = Output(id: 30, uid: "headset", name: "ABO", volume: 0.8, muted: false,
                                 isAggregate: false, transportType: kAudioDeviceTransportTypeBluetooth)

    func testBluetoothReplacesStaleSpeakerSelectionEvenAfterDefaultWasAlreadyRefreshed() {
        let first = AudioOutputSelection.followingSystem(current: headset, selected: [speaker.uid], managedRouteActive: false)
        XCTAssertEqual(first, [headset.uid])
        XCTAssertEqual(AudioOutputSelection.followingSystem(current: headset, selected: first, managedRouteActive: false), first)
    }

    func testBluetoothOwnsKeysWhenSavedMultiOutputGroupIsStopped() {
        XCTAssertEqual(AudioOutputSelection.followingSystem(current: headset, selected: [speaker.uid, "hdmi"],
                                                            managedRouteActive: false), [headset.uid])
    }

    func testBluetoothLEIsAlsoFollowed() {
        let device = Output(id: 40, uid: "le-headset", name: "Headset", volume: 0.6, muted: nil,
                            isAggregate: false, transportType: kAudioDeviceTransportTypeBluetoothLE)
        XCTAssertEqual(AudioOutputSelection.followingSystem(current: device, selected: [speaker.uid],
                                                            managedRouteActive: false), [device.uid])
    }

    func testActiveManagedRouteKeepsItsMembersUntilRoutingShutdownCompletes() {
        let group: Set<String> = [speaker.uid, "hdmi"]
        XCTAssertEqual(AudioOutputSelection.followingSystem(current: headset, selected: group, managedRouteActive: true), group)
    }

    func testHeadsetDisconnectReturnsNativeSelectionToCurrentSpeaker() {
        XCTAssertEqual(AudioOutputSelection.followingSystem(current: speaker, selected: [headset.uid],
                                                            managedRouteActive: false), [speaker.uid])
    }

    func testInactiveMultiOutputSelectionSurvivesOrdinaryNativeRefresh() {
        let group: Set<String> = [speaker.uid, "hdmi"]
        XCTAssertEqual(AudioOutputSelection.followingSystem(current: speaker, selected: group, managedRouteActive: false), group)
        XCTAssertEqual(AudioOutputSelection.followingSystem(current: nil, selected: group, managedRouteActive: false), group)
        let aggregate = Output(id: 50, uid: "multi-output", name: "Group", volume: nil, muted: nil, isAggregate: true)
        XCTAssertEqual(AudioOutputSelection.followingSystem(current: aggregate, selected: group, managedRouteActive: false), group)
    }

    func testStoppedSavedGroupDoesNotSuppressNativeVolumeKeysOrHUD() {
        let group: Set<String> = [speaker.uid, "hdmi"]
        XCTAssertEqual(AudioOutputSelection.followingSystem(current: speaker, selected: group, managedRouteActive: false), group)
        XCTAssertTrue(AudioOutputSelection.usesNativeVolumeKeys(currentID: speaker.id, outputs: [speaker],
                                                               processingAudio: false, controllerID: 0))
        XCTAssertTrue(AudioOutputSelection.usesNativeVolumeKeys(currentID: headset.id, outputs: [headset],
                                                               processingAudio: false, controllerID: 0))
    }

    func testProcessingUsesNativeKeysOnlyAfterControllerOwnsCurrentRoute() {
        for processing in [true, false] {
            XCTAssertFalse(AudioOutputSelection.usesNativeVolumeKeys(currentID: 99, outputs: [speaker],
                                                                    processingAudio: processing, controllerID: 0))
        }
        XCTAssertFalse(AudioOutputSelection.usesNativeVolumeKeys(currentID: speaker.id, outputs: [speaker],
                                                                processingAudio: true, controllerID: 0))
        XCTAssertFalse(AudioOutputSelection.usesNativeVolumeKeys(currentID: speaker.id, outputs: [speaker],
                                                                processingAudio: true, controllerID: 99))
        XCTAssertTrue(AudioOutputSelection.usesNativeVolumeKeys(currentID: 99, outputs: [speaker],
                                                               processingAudio: true, controllerID: 99))
        let hdmi = Output(id: 50, uid: "hdmi", name: "Display", volume: nil, muted: nil, isAggregate: false)
        XCTAssertFalse(AudioOutputSelection.usesNativeVolumeKeys(currentID: hdmi.id, outputs: [speaker, hdmi],
                                                                processingAudio: false, controllerID: 0))
    }

    func testFollowingHeadsetDoesNotOverwriteRememberedGroupOrItsVolume() {
        let group: Set<String> = [speaker.uid, "hdmi"]
        let saved = BluetoothAudioRoute(bluetoothUID: headset.uid, outputUIDs: group, mode: .software, volume: 0.35, muted: true)
        var recovery = BluetoothRouteRecovery(pending: saved)
        XCTAssertEqual(AudioOutputSelection.followingSystem(current: headset, selected: group, managedRouteActive: false), [headset.uid])
        XCTAssertNil(recovery.update(current: headset, outputs: [speaker, headset]))
        XCTAssertEqual(recovery.pending, saved)
    }
}
