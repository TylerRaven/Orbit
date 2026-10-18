import Accelerate
import CoreAudio
import Foundation
import os

/// Listens to whatever the Mac is playing (Spotify, Music, a YouTube tab…) through a Core Audio
/// system tap, and turns it into spectrum levels and beats for the Sonic wallpaper and glows.
/// Audio never leaves the Mac and is never recorded — only loudness per frequency band is kept.
final class MusicListener: @unchecked Sendable {
    static let shared = MusicListener()
    static let bandCount = 48

    struct Snapshot {
        var levels = [Float](repeating: 0, count: MusicListener.bandCount)
        var bass: Float = 0
        var loudness: Float = 0
        var beats = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: Snapshot())
    private let queue = DispatchQueue(label: "orbit.music", qos: .userInteractive)

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private(set) var isRunning = false

    // Analysis (only touched on the audio queue).
    private static let fftSize = 1024
    private let fft = vDSP.FFT(log2n: 10, radix: .radix2, ofType: DSPSplitComplex.self)!
    private let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized,
                                     count: MusicListener.fftSize, isHalfWindow: false)
    private var ring = [Float](repeating: 0, count: MusicListener.fftSize)
    private var ringFill = 0
    private var sampleRate: Float = 48_000
    private var smoothed = [Float](repeating: 0, count: MusicListener.bandCount)
    private var bassAverage: Float = 0
    private var lastBeat = Date.distantPast
    private var beatCount = 0

    func snapshot() -> Snapshot { state.withLock { $0 } }

    // MARK: Start / stop

    /// Starts or stops listening to match the user's settings.
    func sync() {
        let d = UserDefaults.standard
        let wanted = d.string(forKey: Pref.wallpaper) == WallpaperStyle.sonic.rawValue || d.bool(forKey: Pref.musicGlow)
        if wanted && !isRunning { start() } else if !wanted && isRunning { stop() }
    }

    func start() {
        guard !isRunning else { return }
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        desc.uuid = UUID()
        desc.muteBehavior = .unmuted
        desc.isPrivate = true
        desc.name = "Orbit Sonic"

        guard AudioHardwareCreateProcessTap(desc, &tapID) == noErr else { return }

        var format = AudioStreamBasicDescription()
        if Self.get(tapID, kAudioTapPropertyFormat, &format) == noErr, format.mSampleRate > 0 {
            sampleRate = Float(format.mSampleRate)
        }

        var outputID = AudioObjectID(kAudioObjectUnknown)
        _ = Self.get(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultSystemOutputDevice, &outputID)
        let outputUID = Self.uid(of: outputID) ?? ""

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Orbit Sonic",
            kAudioAggregateDeviceUIDKey: "orbit.sonic." + UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: desc.uuid.uuidString,
                                               kAudioSubTapDriftCompensationKey: true]],
        ]
        guard AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &deviceID) == noErr else {
            AudioHardwareDestroyProcessTap(tapID)
            return
        }

        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, deviceID, queue) { [weak self] _, input, _, _, _ in
            self?.consume(input)
        }
        guard status == noErr, AudioDeviceStart(deviceID, procID) == noErr else {
            stop()
            return
        }
        isRunning = true
    }

    func stop() {
        if let procID {
            AudioDeviceStop(deviceID, procID)
            AudioDeviceDestroyIOProcID(deviceID, procID)
        }
        if deviceID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(deviceID) }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        deviceID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        isRunning = false
        state.withLock { $0 = Snapshot() }
    }

    // MARK: Analysis

    private func consume(_ list: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        guard let buffer = buffers.first, let data = buffer.mData else { return }
        let channels = Int(max(1, buffer.mNumberChannels))
        let frames = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / channels
        let samples = data.assumingMemoryBound(to: Float.self)

        for f in 0..<frames {
            var mono: Float = 0
            for c in 0..<channels { mono += samples[f * channels + c] }
            ring[ringFill] = mono / Float(channels)
            ringFill += 1
            if ringFill == Self.fftSize {
                analyze()
                // Overlap by half so updates come ~90 times a second.
                ring.replaceSubrange(0..<Self.fftSize / 2, with: ring[(Self.fftSize / 2)...])
                ringFill = Self.fftSize / 2
            }
        }
    }

    private func analyze() {
        let n = Self.fftSize
        let windowed = vDSP.multiply(ring, window)
        var real = [Float](repeating: 0, count: n / 2)
        var imag = [Float](repeating: 0, count: n / 2)
        var mags = [Float](repeating: 0, count: n / 2)

        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBufferPointer { wp in
                    wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
                fft.forward(input: split, output: &split)
                vDSP_zvabs(&split, 1, &mags, 1, vDSP_Length(n / 2))
            }
        }

        // Log-spaced bands from 40 Hz to 14 kHz, in rough decibels mapped to 0…1.
        let binHz = sampleRate / Float(n)
        let lo: Float = 40, hi: Float = 14_000
        var loudness: Float = 0
        for b in 0..<Self.bandCount {
            let f0 = lo * pow(hi / lo, Float(b) / Float(Self.bandCount))
            let f1 = lo * pow(hi / lo, Float(b + 1) / Float(Self.bandCount))
            let i0 = max(1, Int(f0 / binHz)), i1 = max(i0 + 1, min(n / 2, Int(f1 / binHz)))
            var sum: Float = 0
            for i in i0..<i1 { sum += mags[i] }
            let amp = sum / Float(i1 - i0) * 2 / Float(n)
            let db = 20 * log10(amp + 1e-7)
            // Lift the highs a little so the ring isn't all bass.
            let level = min(1, max(0, (db + 72 + Float(b) * 0.35) / 58))
            smoothed[b] = level > smoothed[b] ? level : smoothed[b] * 0.86 + level * 0.14
            loudness += smoothed[b]
        }
        loudness /= Float(Self.bandCount)

        let bass = smoothed[0..<7].reduce(0, +) / 7
        bassAverage = bassAverage * 0.97 + bass * 0.03
        let now = Date()
        if bass > 0.3, bass > bassAverage * 1.25, now.timeIntervalSince(lastBeat) > 0.22 {
            lastBeat = now
            beatCount += 1
        }

        let snap = Snapshot(levels: smoothed, bass: bass, loudness: loudness, beats: beatCount)
        state.withLock { $0 = snap }
    }

    // MARK: Core Audio helpers

    private static func get<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: inout T) -> OSStatus {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
    }

    private static func uid(of device: AudioObjectID) -> String? {
        var uid: Unmanaged<CFString>?
        guard get(device, kAudioDevicePropertyDeviceUID, &uid) == noErr, let uid else { return nil }
        return uid.takeRetainedValue() as String
    }
}
