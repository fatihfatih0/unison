import XCTest
@testable import Unison

final class LinkedVolumeTests: XCTestCase {
    func testNamedOutputNeverAppliesHardwareVolumeTwice() {
        XCTAssertEqual(NamedOutputGain.device(master: 0.66, relative: 0.8, calibration: 0.5, hardwareControlled: true, muted: false), 1)
        XCTAssertEqual(NamedOutputGain.device(master: 0.66, relative: 0.8, calibration: 0.5, hardwareControlled: false, muted: false), 0.264, accuracy: 0.00001)
    }
    func testNamedOutputMuteAndZeroSilenceHardwareAndHDMI() {
        for hardware in [true, false] {
            XCTAssertEqual(NamedOutputGain.device(master: 0.66, relative: 1, calibration: 1, hardwareControlled: hardware, muted: true), 0)
            XCTAssertEqual(NamedOutputGain.device(master: 0.66, relative: 0, calibration: 1, hardwareControlled: hardware, muted: false), 0)
            XCTAssertEqual(NamedOutputGain.device(master: 0, relative: 1, calibration: 1, hardwareControlled: hardware, muted: false), 0)
        }
    }
    func testCommonVolumeIsAppliedExactlyOnceToSystemSpeaker() {
        let master = 0.4
        let systemGain = LinkedVolumeGain.device(master: master, relative: 0.8, calibration: 0.5, isSystemDevice: true, muted: false)
        let otherGain = LinkedVolumeGain.device(master: master, relative: 0.8, calibration: 0.5, isSystemDevice: false, muted: false)
        XCTAssertEqual(systemGain * master, otherGain, accuracy: 0.00001)
        XCTAssertEqual(otherGain, 0.16, accuracy: 0.00001)
    }
    func testHardwareDecibelCurveIsUsedForOtherSpeakers() {
        let nativeAmplitude = 0.05
        let systemGain = LinkedVolumeGain.device(master: 0.4, relative: 0.8, calibration: 0.5, isSystemDevice: true, muted: false, systemAmplitude: nativeAmplitude)
        let otherGain = LinkedVolumeGain.device(master: 0.4, relative: 0.8, calibration: 0.5, isSystemDevice: false, muted: false, systemAmplitude: nativeAmplitude)
        XCTAssertEqual(systemGain * nativeAmplitude, otherGain, accuracy: 0.00001)
    }
    func testZeroAndMuteSilenceEveryDevice() {
        for system in [true, false] {
            XCTAssertEqual(LinkedVolumeGain.device(master: 0, relative: 1, calibration: 1, isSystemDevice: system, muted: false), 0)
            XCTAssertEqual(LinkedVolumeGain.device(master: 0.7, relative: 1, calibration: 1, isSystemDevice: system, muted: true), 0)
        }
    }
}
