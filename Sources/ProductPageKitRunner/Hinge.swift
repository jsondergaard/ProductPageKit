import CryptoKit
import Foundation
import ProductPageKitCore

/// Sets a foldable simulator's hinge angle. Device Hub's hinge slider sends
/// the angle through CoreDevice, whose simulator side posts it to the HID
/// system as a vendor-defined event, and no `simctl` or `devicectl` command
/// does. This small tool, spawned inside the simulator, posts the same event.
struct Hinge: Sendable {
    let tool: URL

    /// A phone opened flat, which draws on its inner display.
    static let open = 180.0

    /// Compiles the tool into `folder`, under a name that follows its source.
    static func build(in folder: URL) async throws -> Hinge {
        let name = "hinge-" + SHA256.hash(data: Data(source.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        let tool = folder.appending(path: name)
        if FileManager.default.isExecutableFile(atPath: tool.path) { return Hinge(tool: tool) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "\(name).c")
        try Data(source.utf8).write(to: file)
        _ = try await Shell.run("/usr/bin/xcrun", [
            "--sdk", "iphonesimulator", "clang", "-arch", "arm64", "-arch", "x86_64", "-mios-simulator-version-min=17.0",
            "-O2", "-framework", "CoreFoundation", "-framework", "IOKit", file.path, "-o", tool.path,
        ])
        return Hinge(tool: tool)
    }

    /// The event Device Hub's slider sends: a vendor-defined event on Apple's
    /// page 0xFF61, usage 0x5B, carrying a binary-serialized dictionary that
    /// names the slider as its source and the angle in degrees as its value.
    static let source = #"""
    #include <CoreFoundation/CoreFoundation.h>
    #include <mach/mach_time.h>
    #include <stdio.h>
    #include <stdlib.h>

    typedef struct __IOHIDEvent *IOHIDEventRef;
    typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;
    extern IOHIDEventRef IOHIDEventCreateVendorDefinedEvent(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t,
                                                            const uint8_t *, CFIndex, uint32_t);
    extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreateWithType(CFAllocatorRef, int, CFDictionaryRef);
    extern void IOHIDEventSystemClientDispatchEvent(IOHIDEventSystemClientRef, IOHIDEventRef);
    extern CFDataRef IOCFSerialize(CFTypeRef, CFOptionFlags);

    enum { simpleClient = 4, serializeBinary = 1 };

    int main(int argc, char **argv) {
        if (argc != 2) {
            fprintf(stderr, "usage: hinge <degrees>\n");
            return 64;
        }
        double angle = atof(argv[1]);
        CFNumberRef value = CFNumberCreate(NULL, kCFNumberDoubleType, &angle);
        const void *keys[] = {CFSTR("provider"), CFSTR("source"), CFSTR("type"), CFSTR("value")};
        const void *values[] = {CFSTR("com.apple.Virtualization.VirtualMachines"), CFSTR("hinge-slider-control"),
                                CFSTR("range"), value};
        CFDictionaryRef payload = CFDictionaryCreate(NULL, keys, values, 4, &kCFTypeDictionaryKeyCallBacks,
                                                     &kCFTypeDictionaryValueCallBacks);
        CFDataRef data = IOCFSerialize(payload, serializeBinary);
        IOHIDEventSystemClientRef client = IOHIDEventSystemClientCreateWithType(NULL, simpleClient, NULL);
        if (!data || !client) {
            fprintf(stderr, "hinge: no HID event system\n");
            return 1;
        }
        IOHIDEventRef event = IOHIDEventCreateVendorDefinedEvent(NULL, mach_absolute_time(), 0xFF61, 0x5B, 0,
                                                                 CFDataGetBytePtr(data), CFDataGetLength(data), 0);
        IOHIDEventSystemClientDispatchEvent(client, event);
        return 0;
    }
    """#
}

/// How a foldable worker is opened flat and photographed on its inner
/// display.
struct Unfolding: Sendable {
    let display: InnerDisplay
    let hinge: Hinge
}

/// A foldable's inner display: its screen ID, for `simctl io screenshot
/// --display`, and the size it photographs at once opened flat.
struct InnerDisplay: Equatable, Sendable {
    let screenID: Int
    let openSize: CGSize

    /// Whether `frame` shows the display opened. Folded, it photographs at
    /// its unturned size: black before iOS 27.2, a spinner since.
    func showsOpen(_ frame: Frame) -> Bool {
        CGSize(width: frame.image.width, height: frame.image.height) == openSize && frame.showsContent
    }
}
