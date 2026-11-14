import Testing
@testable import Dashboard

/// Pins DetailsSidebar.symbolicPermissions: the pure formatter that turns a POSIX mode
/// into an `ls`-style symbolic string plus the parenthesised octal. Covers the common
/// modes, the directory/file leading char, and the setuid/setgid/sticky special bits
/// (including the uppercase glyphs used when the underlying execute bit is unset).
@Suite struct PermissionFormattingTests {

    @Test(arguments: [
        // Common modes, and the leading `d` for a directory.
        (0o755, false, "-rwxr-xr-x (755)"), (0o644, false, "-rw-r--r-- (644)"),
        (0o600, false, "-rw------- (600)"), (0o777, false, "-rwxrwxrwx (777)"),
        (0o000, false, "---------- (000)"), (0o755, true, "drwxr-xr-x (755)"),
        (0o777, true, "drwxrwxrwx (777)"),
        // setuid, setgid and sticky take the owner, group and other execute slots: lowercase over
        // a set execute bit, uppercase over an unset one.
        (0o4755, false, "-rwsr-xr-x (4755)"), (0o4655, false, "-rwSr-xr-x (4655)"),
        (0o2755, false, "-rwxr-sr-x (2755)"), (0o2745, false, "-rwxr-Sr-x (2745)"),
        (0o1777, true, "drwxrwxrwt (1777)"), (0o1666, false, "-rw-rw-rwT (1666)"),
        // Bits outside 0o7777 (the file-type bits stat can carry) don't leak into the output.
        (0o100644, false, "-rw-r--r-- (644)"),
    ] as [(Int, Bool, String)])
    func aModeReadsAsLsWritesIt(mode: Int, isDirectory: Bool, expected: String) {
        #expect(DetailsSidebar.symbolicPermissions(mode: mode, isDirectory: isDirectory) == expected)
    }
}
