// SocketListenerTests.swift — bind-time perm hardening.
//
// The sidecar's socket carries karaoke utterances from the daemon. A
// world-connectable socket would let any same-uid process pretend to be
// the daemon. SocketListener uses umask(0o077) around bind() to close
// the TOCTOU window between bind (which creates the socket node) and
// the explicit chmod 0o600 that follows. These tests verify both the
// post-bind perms and that the umask is restored.

import XCTest
import Darwin
@testable import MynaKaraokeCore

final class SocketListenerTests: XCTestCase {

    private var tmpDir: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        // sockaddr_un.sun_path is 104 bytes on macOS, and the default
        // NSTemporaryDirectory() under /var/folders/... already eats ~70.
        // Use /tmp with a short UUID suffix to stay safely under the cap.
        let shortId = String(UUID().uuidString.prefix(8))
        tmpDir = "/tmp/myna-k-\(shortId)"
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tmpDir { try? FileManager.default.removeItem(atPath: tmpDir) }
        try super.tearDownWithError()
    }

    /// After start(), the socket node on disk must be 0o600 (owner-only).
    /// This is the post-state — both the umask-during-bind and the
    /// explicit chmod combine to land here.
    func test_socketPerms_areOwnerOnlyAfterStart() throws {
        let sockPath = (tmpDir as NSString).appendingPathComponent("test.sock")
        let listener = SocketListener(socketPath: sockPath)
        try listener.start()
        defer { listener.stop() }

        var st = stat()
        XCTAssertEqual(stat(sockPath, &st), 0, "socket should exist after start()")
        let mode = st.st_mode & 0o777
        XCTAssertEqual(mode, 0o600,
                       String(format: "expected 0o600, got 0o%o", mode))
    }

    /// umask is process-global. The listener must restore the caller's
    /// previous umask after bind() so it doesn't silently tighten file
    /// creation perms for unrelated code paths in the same process.
    func test_callerUmask_isRestoredAfterStart() throws {
        // Choose a sentinel umask different from what bindAndListen sets.
        let sentinel: mode_t = 0o022
        let entry = umask(sentinel)
        defer { umask(entry) }                  // restore whatever was there before

        let sockPath = (tmpDir as NSString).appendingPathComponent("perm-restore.sock")
        let listener = SocketListener(socketPath: sockPath)
        try listener.start()
        defer { listener.stop() }

        // Read current umask without permanently changing it: umask() returns
        // the previous value, so we set-and-restore to peek.
        let observed = umask(sentinel)
        _ = umask(observed)
        XCTAssertEqual(observed, sentinel, "umask must be restored after bindAndListen")
    }
}
