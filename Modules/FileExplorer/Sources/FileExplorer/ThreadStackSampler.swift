import Darwin
import Foundation

/// Samples one thread of this process by walking its frame-pointer chain, from inside the process.
///
/// **Why not leave it to `/usr/bin/sample`.** `sample` takes about half a second to attach, and a
/// stall is noticed a second or more after it starts — so on the installed app a 1.5 s stall had
/// ended before `sample` took its first stack, twice, and the file showed an idle main thread. This
/// starts within microseconds of the stall being noticed.
///
/// **While the thread is suspended, nothing here allocates, locks or symbolicates.** The suspended
/// thread may hold the malloc lock or dyld's, and touching either would deadlock the process
/// against its own main thread. Frames go into a buffer allocated before the first suspend; `dladdr`
/// runs only in `render`, after every resume.
///
/// arm64 only, where Apple's ABI keeps frame pointers. Elsewhere `sample` returns no stacks and the
/// stall file carries `/usr/bin/sample`'s report alone.
enum ThreadStackSampler {
    static let maxDepth = 128

    /// What a run of samples found: the stacks, and the kernel's error when the thread could not
    /// be read, so a file can say which of "not arm64" and "could not read it" happened.
    struct Samples {
        var stacks: [[UInt]] = []
        var failure: kern_return_t?
    }

    /// Samples `thread` every `interval` until `stop()` says so or `limit` passes. Always takes one
    /// stack first: a stall can end while this is still being scheduled, and a file with no stack
    /// at all reads as a failure.
    static func sample(thread: thread_act_t, every interval: TimeInterval, limit: TimeInterval,
                       stop: () -> Bool) -> Samples {
        #if arch(arm64)
        let capacity = max(1, Int(limit / interval) + 1)
        let frames = UnsafeMutablePointer<UInt>.allocate(capacity: capacity * maxDepth)
        defer { frames.deallocate() }
        var depths = [Int](repeating: 0, count: capacity)
        guard let bounds = stackBounds(of: thread) else { return Samples(failure: KERN_INVALID_ARGUMENT) }
        let deadline = Date().addingTimeInterval(limit)
        var taken = 0
        var failure: kern_return_t?
        repeat {
            switch walk(thread, bounds: bounds, into: frames + taken * maxDepth) {
            case .success(let depth): depths[taken] = depth
            case .failure(let error): failure = error.code
            }
            taken += 1
            if taken < capacity, Date() < deadline, !stop() { Thread.sleep(forTimeInterval: interval) } else { break }
        } while true
        let stacks = (0..<taken).compactMap { i in
            depths[i] > 0 ? Array(UnsafeBufferPointer(start: frames + i * maxDepth, count: depths[i])) : nil
        }
        return Samples(stacks: stacks, failure: stacks.isEmpty ? failure : nil)
        #else
        return Samples()
        #endif
    }

    /// One stack of `thread`, innermost first; empty if it could not be read.
    static func snapshot(of thread: thread_act_t) -> [UInt] {
        sample(thread: thread, every: 1, limit: 0, stop: { true }).stacks.first ?? []
    }

    /// Whether `stack` is a thread idle in its OUTERMOST run loop: the kernel's `mach_msg`, then
    /// `__CFRunLoopServiceMachPort`, a single `__CFRunLoopRun`, and below CoreFoundation the frame
    /// that entered it — on the main thread, HIToolbox's event loop. A heartbeat overdue while the
    /// main thread sits there was held back by the system (App Nap, a display asleep), not by the
    /// app: on 10-28 every stall the watch caught on a normal launch was this, with 0.00 s of CPU
    /// and the app inactive and occluded.
    ///
    /// **Every part of the shape is needed.** A nested run loop — `CFRunLoopRunInMode` in a private
    /// mode, a synchronous `CFMessagePortSendRequest`, an Apple Event waiting on its reply — parks
    /// in exactly the same four frames, and an overdue heartbeat there IS a stall: that loop is not
    /// draining the main queue. Those show a second `__CFRunLoopRun`, or a caller other than the
    /// event loop below CoreFoundation. A lock, a semaphore, a sleep or a blocked `open` waits in
    /// the kernel without `mach_msg` at all. Symbolicates, so only call it with the thread running.
    static func isParkedInRunLoop(_ stack: [UInt], enteredFrom entry: String = "HIToolbox") -> Bool {
        let frames = stack.map(frame(of:))
        var i = 0
        while i < frames.count, frames[i].image == "libsystem_kernel.dylib" { i += 1 }
        guard i > 0, i < frames.count, frames[i - 1].symbol.hasPrefix("mach_msg"),
              frames[i].symbol == "__CFRunLoopServiceMachPort",
              frames.filter({ $0.symbol == "__CFRunLoopRun" }).count == 1,
              let caller = frames[i...].first(where: { $0.image != "CoreFoundation" })
        else { return false }
        return caller.image == entry
    }

    /// The innermost `count` frames as "image symbol", for a line about a skipped heartbeat.
    static func describe(_ stack: [UInt], count: Int) -> String {
        stack.prefix(count).map { let f = frame(of: $0); return "\(f.image) \(f.symbol)" }.joined(separator: " < ")
    }

    private static func frame(of address: UInt) -> (image: String, symbol: String) {
        var info = Dl_info()
        guard dladdr(UnsafeRawPointer(bitPattern: address), &info) != 0 else { return ("", "") }
        return (info.dli_fname.map { (String(cString: $0) as NSString).lastPathComponent } ?? "",
                info.dli_sname.map { String(cString: $0) } ?? "")
    }

    #if arch(arm64)
    private static func stackBounds(of thread: thread_act_t) -> (low: UInt, high: UInt)? {
        guard let pthread = pthread_from_mach_thread_np(thread) else { return nil }
        let high = UInt(bitPattern: pthread_get_stackaddr_np(pthread))
        let size = UInt(pthread_get_stacksize_np(pthread))
        return (high - size, high)
    }

    /// Pointer-authentication bits off a return address: system libraries are arm64e, and the
    /// link register and saved returns they leave carry a signature in the top bits.
    private static func strip(_ address: UInt64) -> UInt { UInt(address & 0x0000_7FFF_FFFF_FFFF) }

    /// One stack, innermost first: pc, lr (the caller of a leaf, which pushes no frame), then each
    /// frame's saved return. Writes only into `buffer`; see the type's note.
    private static func walk(_ thread: thread_act_t, bounds: (low: UInt, high: UInt),
                             into buffer: UnsafeMutablePointer<UInt>) -> Result<Int, KernError> {
        let suspended = thread_suspend(thread)
        guard suspended == KERN_SUCCESS else { return .failure(KernError(code: suspended)) }
        defer { thread_resume(thread) }
        var state = arm_thread_state64_t()
        var count = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &state) {
            $0.withMemoryRebound(to: natural_t.self, capacity: Int(count)) {
                thread_get_state(thread, thread_state_flavor_t(ARM_THREAD_STATE64), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return .failure(KernError(code: result)) }
        var depth = 0
        buffer[depth] = strip(state.__pc); depth += 1
        let lr = strip(state.__lr)
        var fp = UInt(state.__fp)
        var firstReturn: UInt?
        while depth < maxDepth, fp >= bounds.low, fp + 16 <= bounds.high, fp % 8 == 0 {
            let record = UnsafePointer<UInt>(bitPattern: fp)!
            let saved = strip(UInt64(record[1]))
            if saved == 0 { break }
            if firstReturn == nil {
                firstReturn = saved
                // A leaf's caller is only in lr; a non-leaf pushed lr as this first saved return.
                if lr != saved, depth < maxDepth { buffer[depth] = lr; depth += 1 }
            }
            if depth < maxDepth { buffer[depth] = saved; depth += 1 }
            let next = record[0]
            if next <= fp { break }   // the chain only ever climbs the stack
            fp = next
        }
        return .success(depth)
    }
    #endif

    struct KernError: Error { let code: kern_return_t }

    /// The distinct stacks, most frequent first, symbolicated. Call only after `sample` returns:
    /// `dladdr` takes dyld's lock.
    static func render(_ samples: Samples, interval: TimeInterval) -> String {
        let stacks = samples.stacks
        guard !stacks.isEmpty else {
            if let failure = samples.failure {
                return "No in-process stacks: the main thread could not be read (kern_return_t \(failure)).\n"
            }
            #if arch(arm64)
            return "No in-process stacks: the main thread’s frame chain was empty.\n"
            #else
            return "No in-process stacks: frame-pointer sampling runs on arm64 only.\n"
            #endif
        }
        var counts: [[UInt]: Int] = [:]
        for stack in stacks { counts[stack, default: 0] += 1 }
        var out = String(format: "Main thread, sampled in-process every %.0f ms from the moment the stall was noticed: %d samples, %d distinct stacks.\n\n",
                         interval * 1000, stacks.count, counts.count)
        for (stack, n) in counts.sorted(by: { $0.value > $1.value }) {
            out += "\(n) of \(stacks.count):\n"
            for (i, address) in stack.enumerated() { out += "  \(i)  \(symbol(address))\n" }
            out += "\n"
        }
        return out
    }

    private static func symbol(_ address: UInt) -> String {
        var info = Dl_info()
        guard dladdr(UnsafeRawPointer(bitPattern: address), &info) != 0 else {
            return String(format: "0x%lx", address)
        }
        let image = info.dli_fname.map { (String(cString: $0) as NSString).lastPathComponent } ?? "?"
        guard let name = info.dli_sname, let start = info.dli_saddr else {
            return String(format: "%@  0x%lx", image, address)
        }
        let offset = address - UInt(bitPattern: start)
        return "\(image)  \(demangle(String(cString: name))) + \(offset)"
    }

    /// The Swift runtime's own demangler, which is exported but not declared to Swift.
    private static func demangle(_ name: String) -> String {
        typealias Demangle = @convention(c) (UnsafePointer<CChar>?, Int, UnsafeMutablePointer<CChar>?,
                                             UnsafeMutablePointer<Int>?, UInt32) -> UnsafeMutablePointer<CChar>?
        guard let handle = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "swift_demangle") else { return name }
        let fn = unsafeBitCast(handle, to: Demangle.self)
        return name.withCString { cName in
            guard let result = fn(cName, strlen(cName), nil, nil, 0) else { return name }
            defer { free(result) }
            return String(cString: result)
        }
    }
}
