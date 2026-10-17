import CMainStack
import Foundation
import MachO
import Testing

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
