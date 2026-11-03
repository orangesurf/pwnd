import Foundation

/// The GitHub token, stored in the login keychain through Apple's
/// `/usr/bin/security` tool, as GitHub's `gh` CLI does on macOS.
///
/// Why not the Security framework directly: a keychain item remembers which
/// app may read it by that app's code signature. pwnd is ad-hoc signed, so
/// every build has a new signature and macOS would ask for the login password
/// after each update. Items created by `/usr/bin/security` list that tool as
/// the trusted app; it is signed by Apple and stable, so there is no prompt.
/// The trade-off, same as gh's: any program running as this user can ask
/// `security` for the token. It can only read public repositories.
///
/// The token is passed to `security -i` on standard input, never as a
/// command-line argument, so it does not appear in the process list.
enum Keychain {
    static let service = "pwnd-github-token"
    static let account = "github"
    private static let tool = URL(fileURLWithPath: "/usr/bin/security")

    /// GitHub tokens are letters, digits, underscores and hyphens
    /// (`ghp_…`, `github_pat_…`). Anything else is refused before it reaches
    /// the `security` command line parser.
    static func isWellFormed(_ token: String) -> Bool {
        !token.isEmpty && token.count <= 255
            && token.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "_" || $0 == "-" }
    }

    static func readToken() -> String? {
        let r = run(["find-generic-password", "-s", service, "-a", account, "-w"])
        guard r.status == 0 else { return nil }
        let token = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    @discardableResult
    static func saveToken(_ token: String) -> Bool {
        guard isWellFormed(token) else { return false }
        let command = "add-generic-password -U -s \"\(service)\" -a \"\(account)\" -l \"pwnd GitHub token\" -w \"\(token)\"\n"
        let r = run(["-i"], stdin: command)
        // `security -i` exits 0 even when a command fails; it reports the
        // failure as "returned <code>" on stderr. Confirm by reading it back.
        return r.status == 0 && !r.err.contains("returned") && readToken() == token
    }

    static func deleteToken() {
        _ = run(["delete-generic-password", "-s", service, "-a", account])
    }

    private static func run(_ args: [String], stdin: String? = nil) -> (status: Int32, out: String, err: String) {
        let p = Process()
        p.executableURL = tool
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        let input = Pipe()
        p.standardInput = stdin == nil ? FileHandle.nullDevice : input
        do { try p.run() } catch { return (-1, "", error.localizedDescription) }
        if let stdin {
            input.fileHandleForWriting.write(Data(stdin.utf8))
            try? input.fileHandleForWriting.close()
        }
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: o, as: UTF8.self), String(decoding: e, as: UTF8.self))
    }
}
