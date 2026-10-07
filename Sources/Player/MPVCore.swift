import Foundation
import Libmpv
import QuartzCore

/// Thread-safe wrapper around one mpv handle. Every mpv API call goes through here,
/// and events are delivered on a private queue through `onEvent`.
final class MPVCore: @unchecked Sendable {
    enum Event: Sendable {
        case log(level: String, prefix: String, text: String)
        case propertyChanged(String)
        case fileLoaded
        case endFile(error: String?)
    }

    private let lock = NSLock()
    private var handle: OpaquePointer?
    private let queue = DispatchQueue(label: "mpv.events", qos: .userInitiated)
    private let onEvent: @Sendable (Event) -> Void

    /// Creates and initializes mpv, rendering into `layer`. Returns nil if mpv fails to start.
    init?(
        layer: CAMetalLayer,
        options: [(String, String)],
        observedProperties: [String],
        logLevel: String,
        onEvent: @escaping @Sendable (Event) -> Void
    ) {
        guard let handle = mpv_create() else { return nil }
        self.handle = handle
        self.onEvent = onEvent

        // mpv reads the layer's address from "wid".
        var layerReference = layer
        _ = mpv_set_option(handle, "wid", MPV_FORMAT_INT64, &layerReference)

        for (name, value) in options {
            let status = mpv_set_option_string(handle, name, value)
            if status < 0 {
                onEvent(.log(level: "error", prefix: "app", text: "Option \(name)=\(value) failed: \(Self.errorString(status))"))
            }
        }
        _ = mpv_request_log_messages(handle, logLevel)

        let status = mpv_initialize(handle)
        guard status >= 0 else {
            onEvent(.log(level: "error", prefix: "app", text: "mpv_initialize failed: \(Self.errorString(status))"))
            mpv_terminate_destroy(handle)
            self.handle = nil
            return nil
        }

        for name in observedProperties {
            _ = mpv_observe_property(handle, 0, name, MPV_FORMAT_NONE)
        }

        // Retained until shutdown() so the callback context stays valid.
        let context = Unmanaged.passRetained(self).toOpaque()
        mpv_set_wakeup_callback(handle, { context in
            guard let context else { return }
            let core = Unmanaged<MPVCore>.fromOpaque(context).takeUnretainedValue()
            core.scheduleDrain()
        }, context)
    }

    /// Stops playback and destroys the mpv handle. Safe to call more than once.
    func shutdown() {
        lock.lock()
        guard let handle else {
            lock.unlock()
            return
        }
        self.handle = nil
        lock.unlock()

        mpv_set_wakeup_callback(handle, nil, nil)
        queue.async {
            mpv_terminate_destroy(handle)
            Unmanaged.passUnretained(self).release()
        }
    }

    // MARK: - Commands and properties

    @discardableResult
    func command(_ args: [String]) -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { return -1 }

        var cArgs: [UnsafePointer<CChar>?] = args.map { UnsafePointer<CChar>(strdup($0)) }
        cArgs.append(nil)
        defer {
            for pointer in cArgs {
                free(UnsafeMutablePointer(mutating: pointer))
            }
        }
        return mpv_command(handle, &cArgs)
    }

    func string(_ name: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let handle, let cString = mpv_get_property_string(handle, name) else { return nil }
        defer { mpv_free(cString) }
        return String(cString: cString)
    }

    func double(_ name: String) -> Double? {
        string(name).flatMap { Double($0) }
    }

    func flag(_ name: String) -> Bool {
        string(name) == "yes"
    }

    @discardableResult
    func setString(_ name: String, _ value: String) -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { return -1 }
        return mpv_set_property_string(handle, name, value)
    }

    static func errorString(_ status: Int32) -> String {
        guard let cString = mpv_error_string(status) else { return "error \(status)" }
        return String(cString: cString)
    }

    // MARK: - Events

    private func scheduleDrain() {
        queue.async {
            self.drain()
        }
    }

    private func drain() {
        while true {
            lock.lock()
            guard let handle, let eventPointer = mpv_wait_event(handle, 0) else {
                lock.unlock()
                return
            }
            let event = eventPointer.pointee
            if event.event_id == MPV_EVENT_NONE {
                lock.unlock()
                return
            }
            // Event data is only valid until the next mpv_wait_event, so convert it while locked.
            let converted = Self.convert(event)
            lock.unlock()

            if let converted {
                onEvent(converted)
            }
        }
    }

    private static func convert(_ event: mpv_event) -> Event? {
        switch event.event_id {
        case MPV_EVENT_LOG_MESSAGE:
            guard let data = event.data else { return nil }
            let message = data.assumingMemoryBound(to: mpv_event_log_message.self).pointee
            let text = String(cString: message.text).trimmingCharacters(in: .whitespacesAndNewlines)
            return .log(level: String(cString: message.level), prefix: String(cString: message.prefix), text: text)
        case MPV_EVENT_PROPERTY_CHANGE:
            guard let data = event.data else { return nil }
            let property = data.assumingMemoryBound(to: mpv_event_property.self).pointee
            return .propertyChanged(String(cString: property.name))
        case MPV_EVENT_FILE_LOADED:
            return .fileLoaded
        case MPV_EVENT_END_FILE:
            guard let data = event.data else { return .endFile(error: nil) }
            let endFile = data.assumingMemoryBound(to: mpv_event_end_file.self).pointee
            if endFile.reason == MPV_END_FILE_REASON_ERROR {
                return .endFile(error: errorString(endFile.error))
            }
            return .endFile(error: nil)
        default:
            return nil
        }
    }
}
