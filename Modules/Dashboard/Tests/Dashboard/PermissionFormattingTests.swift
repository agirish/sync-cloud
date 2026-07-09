import Testing
@testable import Dashboard

/// Pins DetailsSidebar.symbolicPermissions: the pure formatter that turns a POSIX mode
/// into an `ls`-style symbolic string plus the parenthesised octal. Covers the common
/// modes, the directory/file leading char, and the setuid/setgid/sticky special bits
/// (including the uppercase glyphs used when the underlying execute bit is unset).
@Suite struct PermissionFormattingTests {

    @Test func commonFileModes() {
        #expect(DetailsSidebar.symbolicPermissions(mode: 0o755, isDirectory: false) == "-rwxr-xr-x (755)")
        #expect(DetailsSidebar.symbolicPermissions(mode: 0o644, isDirectory: false) == "-rw-r--r-- (644)")
        #expect(DetailsSidebar.symbolicPermissions(mode: 0o600, isDirectory: false) == "-rw------- (600)")
        #expect(DetailsSidebar.symbolicPermissions(mode: 0o777, isDirectory: false) == "-rwxrwxrwx (777)")
        #expect(DetailsSidebar.symbolicPermissions(mode: 0o000, isDirectory: false) == "---------- (000)")
    }

    @Test func directoryLeadingCharVersusFile() {
        #expect(DetailsSidebar.symbolicPermissions(mode: 0o755, isDirectory: true) == "drwxr-xr-x (755)")
        #expect(DetailsSidebar.symbolicPermissions(mode: 0o755, isDirectory: false) == "-rwxr-xr-x (755)")
        // A wide-open directory is a common real-world case (e.g. /tmp without sticky).
        #expect(DetailsSidebar.symbolicPermissions(mode: 0o777, isDirectory: true) == "drwxrwxrwx (777)")
    }

    @Test func setuidRendersInOwnerExecuteSlot() {
        // Execute bit set → lowercase `s`.
        #expect(DetailsSidebar.symbolicPermissions(mode: 0o4755, isDirectory: false) == "-rwsr-xr-x (4755)")
        // Execute bit unset → uppercase `S`.
        #expect(DetailsSidebar.symbolicPermissions(mode: 0o4655, isDirectory: false) == "-rwSr-xr-x (4655)")
    }

    @Test func setgidRendersInGroupExecuteSlot() {
        // Execute bit set → lowercase `s`.
        #expect(DetailsSidebar.symbolicPermissions(mode: 0o2755, isDirectory: false) == "-rwxr-sr-x (2755)")
        // Execute bit unset → uppercase `S`.
        #expect(DetailsSidebar.symbolicPermissions(mode: 0o2745, isDirectory: false) == "-rwxr-Sr-x (2745)")
    }

    @Test func stickyBitRendersInOtherExecuteSlot() {
        // Classic sticky /tmp directory: execute bit set → lowercase `t`.
        #expect(DetailsSidebar.symbolicPermissions(mode: 0o1777, isDirectory: true) == "drwxrwxrwt (1777)")
        // Execute bit unset → uppercase `T`.
        #expect(DetailsSidebar.symbolicPermissions(mode: 0o1666, isDirectory: false) == "-rw-rw-rwT (1666)")
    }

    @Test func bitsAboveTheStandardMaskAreIgnored() {
        // Anything outside 0o7777 (e.g. the file-type bits stat can carry) must not leak
        // into the output; masking keeps it to the permission + special bits.
        #expect(DetailsSidebar.symbolicPermissions(mode: 0o100644, isDirectory: false) == "-rw-r--r-- (644)")
    }
}
