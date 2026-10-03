import Foundation

/// Guest audio output.
protocol AudioOutput: AnyObject {
    var volume: Float { get set }
    func configure(sampleRate: Double)
    func enqueue(samples: [Float])
    func pause()
    func resume()
}

extension AudioOutput {
    func configure(sampleRate: Double) {}
}
