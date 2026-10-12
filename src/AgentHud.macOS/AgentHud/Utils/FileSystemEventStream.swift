import Foundation

#if canImport(CoreServices)
import CoreServices

public final class FileSystemEventStream {
    public var onChange: (() -> Void)?
    private let path: String
    private let recursive: Bool
    private var stream: FSEventStreamRef?

    public init(path: String, recursive: Bool = true) throws {
        self.path = path
        self.recursive = recursive
    }

    public func start() {
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info = info else { return }
            let stream = Unmanaged<FileSystemEventStream>.fromOpaque(info).takeUnretainedValue()
            stream.onChange?()
        }
        let pathsToWatch = [path] as CFArray
        stream = FSEventStreamCreate(
            nil,
            callback,
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
        )
        guard let stream = stream else { return }
        FSEventStreamScheduleWithRunLoop(stream, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        FSEventStreamStart(stream)
    }

    public func stop() {
        guard let stream = stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}

#else
public final class FileSystemEventStream {
    public var onChange: (() -> Void)?
    public init(path: String, recursive: Bool = true) throws {}
    public func start() {}
    public func stop() {}
}
#endif
