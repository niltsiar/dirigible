import CMainStack
import Foundation
import MachO
import Testing
import os

/// The C part of the hang watchdog (decision 0059): the PAC mask and the image list.
struct MainStackTests {
    /// C42: on any architecture, so this x86_64 Mac runs it too.
    @Test func theMaskClearsThePACBitsOnly() {
        #expect(ms_strip_pac(0x8a1d_0001_8a2b_3c4d) == 0x0000_0001_8a2b_3c4d)
        #expect(ms_strip_pac(0x0000_7fff_fe00_0000) == 0x0000_7fff_fe00_0000)
    }

    /// C49: a library that loads after the start is in the list, and each image of dyld is in it
    /// once with its own UUID.
    @Test func anImageLoadedAfterTheStartIsInTheList() async throws {
        ms_images_start()
        let candidates = [
            "/usr/lib/libsqlite3.dylib", "/usr/lib/libxslt.1.dylib", "/usr/lib/libexslt.0.dylib",
            "/usr/lib/libpcap.A.dylib", "/usr/lib/libedit.3.dylib",
        ]
        let library = try #require(
            candidates.first { path in
                guard let handle = dlopen(path, RTLD_LAZY | RTLD_NOLOAD) else { return true }
                dlclose(handle)
                return false
            }, "each library of the list is loaded already, so no image can load after the start")
        try #require(dlopen(library, RTLD_NOW) != nil, "dlopen \(library): \(String(cString: dlerror()))")

        let images = (0..<_dyld_image_count()).compactMap { index -> (header: UInt, name: String)? in
            guard let header = _dyld_get_image_header(index) else { return nil }
            return (UInt(bitPattern: header), String(cString: _dyld_get_image_name(index)))
        }
        let added = try #require(images.first { $0.name == library }?.header, "dyld has no image \(library)")
        // A suite that loads an image at the same time can be inside the callback for a moment.
        var list = imageList()
        for _ in 0..<100 where !images.allSatisfy({ list[$0.header] != nil }) {
            try await Task.sleep(for: .milliseconds(10))
            list = imageList()
        }

        #expect(list[added]?.count == 1, "the list has \(list[added]?.count ?? 0) entries for \(library)")
        let wrong = images.filter { image in
            guard let entries = list[image.header], entries.count == 1 else { return true }
            return entries[0] != uuid(of: image.header)
        }
        #expect(wrong.isEmpty, "\(wrong.count) of \(images.count) images are missing, twice, or with another UUID")
        #expect(ms_images_dropped() == 0)
    }

    /// C10: a thread that waits in the `read` stub, which has no frame record. The frame after
    /// the pc is the function that called the stub.
    @Test func theWalkNamesTheCallerOfAStubWithNoFrame() async throws {
        var pipe: [Int32] = [-1, -1]
        try #require(Darwin.pipe(&pipe) == 0)
        defer { for descriptor in pipe { close(descriptor) } }
        let reader = pipe[0]
        let thread = await startThread { readInsideTheTestFunction(reader) }

        let frames = try #require(
            await walk(thread, until: { $0.first.map(symbol)?.hasPrefix("read") == true }), "no walk in read")
        _ = write(pipe[1], [UInt8(1)], 1)

        #expect(frames.count >= 3, "\(frames.count) frames")
        let caller = frames.dropFirst().first.map { symbol($0 - 1) } ?? "none"
        #expect(caller.contains("readInsideTheTestFunction"), "frame 1: \(caller)")
    }

    /// C10: a thread in a loop of a function with a frame record. The frame after the pc comes
    /// from the record, never from a word of the stack.
    @Test func theWalkOfAFunctionWithAFrameAddsNoStackWord() async throws {
        nonisolated(unsafe) let spinning = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
        spinning.initialize(to: 1)
        let thread = await startThread { spinInsideTheTestFunction(spinning) }
        defer { spinning.pointee = 0 }

        let frames = try #require(await walk(thread, until: { $0.count >= 2 }), "no walk of 2 frames")
        spinning.pointee = 0

        let inStack = frames.dropFirst().filter { $0 >= thread.stack_low && $0 < thread.stack_high }
        #expect(inStack.isEmpty, "stack addresses as frames: \(inStack.map { String($0, radix: 16) })")
        let caller = frames.dropFirst().first.map { symbol($0 - 1) } ?? "none"
        #expect(caller != "?", "frame 1 has no name")
    }

    /// The UUIDs of the list for each header address.
    func imageList() -> [UInt: [[UInt8]]] {
        var list: [UInt: [[UInt8]]] = [:]
        for index in 0..<ms_images_count() {
            var header: UInt = 0
            var slide = 0
            var bytes = [UInt8](repeating: 0, count: 16)
            guard ms_image_at(index, &header, &slide, &bytes) else { continue }
            list[header, default: []].append(bytes)
        }
        return list
    }

    /// The `LC_UUID` of the mapped 64-bit header at `address`.
    func uuid(of address: UInt) -> [UInt8]? {
        guard let raw = UnsafeRawPointer(bitPattern: address) else { return nil }
        let header = raw.load(as: mach_header_64.self)
        var command = raw + MemoryLayout<mach_header_64>.size
        for _ in 0..<header.ncmds {
            let load = command.load(as: load_command.self)
            if load.cmd == UInt32(LC_UUID) {
                return withUnsafeBytes(of: command.load(as: uuid_command.self).uuid) { Array($0) }
            }
            command += Int(load.cmdsize)
        }
        return nil
    }
}

/// Starts a thread that runs `body` and returns the thread once it runs.
private func startThread(_ body: @escaping @Sendable () -> Void) async -> ms_thread {
    let thread = OSAllocatedUnfairLock<ms_thread?>(initialState: nil)
    Thread {
        thread.withLock { $0 = ms_thread_current() }
        body()
    }.start()
    let end = ContinuousClock.now + .seconds(5)
    while ContinuousClock.now < end, thread.withLock({ $0 }) == nil { try? await Task.sleep(for: .milliseconds(5)) }
    return thread.withLock { $0 } ?? ms_thread()
}

/// The frames of the first walk of `thread` that `done` accepts, at most 5 s of walks.
private func walk(_ thread: ms_thread, until done: ([UInt]) -> Bool) async -> [UInt]? {
    var frames = [UInt](repeating: 0, count: 128)
    let end = ContinuousClock.now + .seconds(5)
    while ContinuousClock.now < end {
        let result = ms_walk(thread, &frames, Int32(frames.count))
        let stack = Array(frames.prefix(Int(result.count)))
        if result.status == KERN_SUCCESS, done(stack) { return stack }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return nil
}

/// The symbol of `address` from `dladdr`, or `?`.
private func symbol(_ address: UInt) -> String {
    var info = Dl_info()
    guard let pointer = UnsafeRawPointer(bitPattern: address), dladdr(pointer, &info) != 0, let name = info.dli_sname
    else { return "?" }
    return String(cString: name)
}

/// Waits in `read(2)` until a byte comes. Internal, so `dladdr` names it.
@inline(never) func readInsideTheTestFunction(_ descriptor: Int32) {
    var byte: UInt8 = 0
    _ = read(descriptor, &byte, 1)
    withExtendedLifetime(byte) {}
}

/// Loops until `spinning` is 0.
@inline(never) func spinInsideTheTestFunction(_ spinning: UnsafeMutablePointer<Int32>) {
    while spinning.pointee != 0 {}
    withExtendedLifetime(spinning) {}
}
