import Foundation
import IOKit
import StradaMAMMedia

/// Finds how a card, drive or iPhone is connected, from the I/O Registry: the USB link a device
/// negotiated, or Thunderbolt.
enum LinkSpeedProbe {
    /// The connection of the device holding the volume at `path`. Nil for an internal disk, a
    /// network share, or a device that does not say.
    static func forVolume(at path: String) -> LinkSpeed? {
        var stats = statfs()
        guard statfs(path, &stats) == 0 else { return nil }
        let device = withUnsafeBytes(of: &stats.f_mntfromname) { bytes in
            String(cString: bytes.bindMemory(to: CChar.self).baseAddress!)
        }
        guard device.hasPrefix("/dev/") else { return nil }
        let bsdName = String(device.dropFirst("/dev/".count))
        guard let matching = IOBSDNameMatching(kIOMainPortDefault, 0, bsdName) else { return nil }
        let media = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard media != 0 else { return nil }
        return walkUp(from: media)
    }

    /// The connection of the USB device at this location, e.g. an iPhone found by Image Capture.
    static func forUSBLocation(_ locationID: Int) -> LinkSpeed? {
        guard locationID != 0, let matching = IOServiceMatching("IOUSBHostDevice") else { return nil }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        while true {
            let device = IOIteratorNext(iterator)
            guard device != 0 else { return nil }
            let matches = number(device, "locationID")?.intValue == locationID
            let speed = matches ? usbSpeed(of: device) : nil
            IOObjectRelease(device)
            if matches { return speed }
        }
    }

    /// From a disk up through its parents to the USB device or Thunderbolt port it hangs from.
    /// Takes ownership of `start`.
    private static func walkUp(from start: io_object_t) -> LinkSpeed? {
        var entry = start
        for _ in 0..<64 {
            if IOObjectConformsTo(entry, "IOUSBHostDevice") != 0 {
                let speed = usbSpeed(of: entry)
                IOObjectRelease(entry)
                return speed
            }
            let className = IOObjectCopyClass(entry).map { $0.takeRetainedValue() as String } ?? ""
            if className.contains("Thunderbolt") {
                IOObjectRelease(entry)
                return .thunderbolt
            }
            var parent: io_object_t = 0
            let result = IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent)
            IOObjectRelease(entry)
            guard result == KERN_SUCCESS, parent != 0 else { return nil }
            entry = parent
        }
        IOObjectRelease(entry)
        return nil
    }

    private static func usbSpeed(of device: io_object_t) -> LinkSpeed? {
        // Newer systems give the link in bits per second; older ones a speed code.
        if let bits = number(device, "UsbLinkSpeed")?.doubleValue, bits > 0 { return .usb(bitsPerSecond: bits) }
        for key in ["USBSpeed", "Device Speed"] {
            if let code = number(device, key)?.intValue, let speed = LinkSpeed.usb(code: code) { return speed }
        }
        return nil
    }

    private static func number(_ entry: io_object_t, _ key: String) -> NSNumber? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber
    }
}
