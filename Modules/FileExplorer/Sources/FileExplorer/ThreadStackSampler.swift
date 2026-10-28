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

    /// Samples `thread` every `interval` until `stop()` says so or `limit` passes.
    static func sample(thread: thread_act_t, every interval: TimeInterval, limit: TimeInterval,
                       stop: () -> Bool) -> [[UInt]] {
        #if arch(arm64)
        let capacity = max(1, Int(limit / interval) + 1)
        let frames = UnsafeMutablePointer<UInt>.allocate(capacity: capacity * maxDepth)
        defer { frames.deallocate() }
        var depths = [Int](repeating: 0, count: capacity)
        guard let bounds = stackBounds(of: thread) else { return [] }
        let deadline = Date().addingTimeInterval(limit)
        var taken = 0
        while taken < capacity, Date() < deadline, !stop() {
            depths[taken] = walk(thread, bounds: bounds, into: frames + taken * maxDepth)
            taken += 1
            Thread.sleep(forTimeInterval: interval)
        }
        return (0..<taken).compactMap { i in
            depths[i] > 0 ? Array(UnsafeBufferPointer(start: frames + i * maxDepth, count: depths[i])) : nil
        }
        #else
        return []
        #endif
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
                             into buffer: UnsafeMutablePointer<UInt>) -> Int {
        guard thread_suspend(thread) == KERN_SUCCESS else { return 0 }
        defer { thread_resume(thread) }
        var state = arm_thread_state64_t()
        var count = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &state) {
            $0.withMemoryRebound(to: natural_t.self, capacity: Int(count)) {
                thread_get_state(thread, thread_state_flavor_t(ARM_THREAD_STATE64), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
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
        return depth
    }
    #endif

    /// The distinct stacks, most frequent first, symbolicated. Call only after `sample` returns:
    /// `dladdr` takes dyld's lock.
    static func render(_ stacks: [[UInt]], interval: TimeInterval) -> String {
        guard !stacks.isEmpty else { return "No in-process stacks (not arm64, or the thread could not be read).\n" }
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
