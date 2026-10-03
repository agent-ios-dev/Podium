import AVFAudio
import Foundation

/// Bounded stereo PCM queue. Guest stalls produce silence; excess audio
/// drops the oldest frames rather than growing latency or guest memory.
final class StereoAudioQueue {
    private let lock = NSLock()
    private var storage: [Float]
    private var head = 0
    private var count = 0
    private var gain: Float = 1
    init(capacityFrames: Int = 12_000) {
        storage = [Float](repeating: 0, count: max(1, capacityFrames) * 2)
    }
    var volume: Float {
        get { lock.lock(); defer { lock.unlock() }; return gain }
        set { lock.lock(); gain = newValue.isFinite ? min(1, max(0, newValue)) : 0; lock.unlock() }
    }
    func clear() { lock.lock(); head = 0; count = 0; lock.unlock() }
    func enqueue(_ samples: [Float]) {
        lock.lock(); defer { lock.unlock() }
        let end = samples.count & ~1
        let start = max(0, end - storage.count)
        for i in stride(from: start, to: end, by: 2) {
            if count == storage.count { head = (head + 2) % storage.count; count -= 2 }
            let tail = (head + count) % storage.count
            storage[tail] = samples[i].isFinite ? min(1, max(-1, samples[i])) : 0
            storage[tail + 1] = samples[i + 1].isFinite ? min(1, max(-1, samples[i + 1])) : 0
            count += 2
        }
    }
    /// Called by the host audio render thread; no allocation or guest access.
    func render(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
        lock.lock(); defer { lock.unlock() }
        for frame in 0..<frames {
            if count >= 2 {
                left[frame] = storage[head] * gain
                right[frame] = storage[head + 1] * gain
                head = (head + 2) % storage.count; count -= 2
            } else { left[frame] = 0; right[frame] = 0 }
        }
    }
}

/// Plays guest PCM on the host's current route (speaker, headphones or
/// Bluetooth). AVAudioEngine converts the guest rate to the route's rate.
final class DeviceAudioOutput: AudioOutput {
    private let pcm = StereoAudioQueue()
    private let control = DispatchQueue(label: "Podium audio output")
    private var engine: AVAudioEngine?
    private var rate: Double = 44_100
    private var running = false
    private var interrupted = false
    private var observers: [NSObjectProtocol] = []
    var volume: Float { get { pcm.volume } set { pcm.volume = newValue } }
    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil) { [weak self] _ in
            self?.control.async { [weak self] in self?.rebuild() }
        })
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue
            self?.control.async { [weak self] in
                guard let self else { return }
                if type == AVAudioSession.InterruptionType.began.rawValue {
                    self.interrupted = true; self.engine?.pause(); self.pcm.clear()
                } else { self.interrupted = false; self.rebuild() }
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: nil) { [weak self] _ in
            self?.control.async { [weak self] in self?.rebuild() }
        })
    }
    deinit { observers.forEach(NotificationCenter.default.removeObserver); engine?.stop() }
    func configure(sampleRate: Double) {
        guard sampleRate >= 8_000, sampleRate <= 96_000, sampleRate.isFinite else { return }
        control.async { [weak self] in
            guard let self, self.rate != sampleRate else { return }
            self.rate = sampleRate; self.pcm.clear(); self.rebuild()
        }
    }
    func enqueue(samples: [Float]) { pcm.enqueue(samples) }
    func resume() { control.async { [weak self] in self?.running = true; self?.rebuild() } }
    func pause() { control.async { [weak self] in
        guard let self else { return }
        self.running = false; self.engine?.stop(); self.engine = nil; self.pcm.clear()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    } }
    private func rebuild() {
        engine?.stop(); engine = nil
        guard running, !interrupted else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            if session.category != .playback { try session.setCategory(.playback, mode: .default) }
            try session.setActive(true)
            let engine = AVAudioEngine()
            let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
            let pcm = self.pcm
            let source = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList in
                let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
                guard buffers.count >= 2,
                      let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                      let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return -50 }
                pcm.render(left: left, right: right, frames: Int(frameCount))
                return 0
            }
            engine.attach(source)
            engine.connect(source, to: engine.mainMixerNode, format: format)
            try engine.start(); self.engine = engine
        } catch { print("Podium audio output: \(error)") }
    }
}
