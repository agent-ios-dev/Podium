import XCTest
@testable import Podium

final class StereoAudioQueueTests: XCTestCase {
    private func drain(_ queue: StereoAudioQueue, frames: Int) -> [[Float]] {
        var left = [Float](repeating: 99, count: frames)
        var right = left
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in queue.render(left: l.baseAddress!, right: r.baseAddress!, frames: frames) }
        }
        return [left, right]
    }
    func testStereoOrderGainAndUnderrunSilence() {
        let queue = StereoAudioQueue(capacityFrames: 4)
        queue.volume = 0.5
        queue.enqueue([0.2, -0.4, 0.6, -0.8])
        let samples = drain(queue, frames: 3)
        XCTAssertEqual(samples[0], [0.1, 0.3, 0])
        XCTAssertEqual(samples[1], [-0.2, -0.4, 0])
    }
    func testOverflowKeepsNewestWholeFramesAndClearDropsPendingSound() {
        let queue = StereoAudioQueue(capacityFrames: 2)
        queue.enqueue([0.1, 0.2, 0.3, 0.4])
        queue.enqueue([0.5, 0.6])
        XCTAssertEqual(drain(queue, frames: 2), [[0.3, 0.5], [0.4, 0.6]])
        queue.enqueue([0.7, 0.8]); queue.clear()
        XCTAssertEqual(drain(queue, frames: 2), [[0, 0], [0, 0]])
    }
}
