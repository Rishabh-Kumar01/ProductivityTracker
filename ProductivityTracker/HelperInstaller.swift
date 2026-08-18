//
//  HelperInstaller.swift
//  ProductivityTracker
//
//  One-time passwordless helper setup via sudoers.
//  Installs a shell script at /usr/local/bin/productivity-hosts-helper
//  and a sudoers entry so the app can modify /etc/hosts without admin prompts.
//

import Foundation

class HelperInstaller {
    static let shared = HelperInstaller()

    static let helperPath = "/usr/local/bin/productivity-hosts-helper"
    static let sudoersPath = "/etc/sudoers.d/productivity-tracker"

    private(set) var isInstalled: Bool = false

    private init() {
        checkInstallation()
    }

    func checkInstallation() {
        isInstalled = FileManager.default.fileExists(atPath: Self.helperPath) &&
                      FileManager.default.fileExists(atPath: Self.sudoersPath)
    }

    // MARK: - Helper Script Content

    private let helperScriptContent = """
    #!/bin/bash
    # ProductivityTracker hosts file manager
    # Called by the app to modify /etc/hosts without an admin password prompt.
    # Installed once via sudoers — see HelperInstaller.swift.

    ACTION="$1"
    BLOCK_FILE="$2"

    MARKER_START="# ===== PRODUCTIVITYTRACKER-BLOCK-START ====="
    MARKER_END="# ===== PRODUCTIVITYTRACKER-BLOCK-END ====="

    case "$ACTION" in
        apply)
            # Remove old block section
            sed -i '' "/$MARKER_START/,/$MARKER_END/d" /etc/hosts
            # Append new block section from file
            if [ -f "$BLOCK_FILE" ]; then
                echo "" >> /etc/hosts
                echo "$MARKER_START" >> /etc/hosts
                cat "$BLOCK_FILE" >> /etc/hosts
                echo "$MARKER_END" >> /etc/hosts
            fi
            # Flush DNS
            dscacheutil -flushcache
            killall -HUP mDNSResponder 2>/dev/null
            ;;
        remove)
            # Remove block section only
            sed -i '' "/$MARKER_START/,/$MARKER_END/d" /etc/hosts
            dscacheutil -flushcache
            killall -HUP mDNSResponder 2>/dev/null
            ;;
        hash)
            # Print SHA-256 hash of the block section
            sed -n "/$MARKER_START/,/$MARKER_END/p" /etc/hosts | shasum -a 256 | cut -d' ' -f1
            ;;
    esac
    """

    // MARK: - Installation

    /// Installs the helper script and sudoers entry. Shows ONE admin password prompt.
    /// If already installed, this is a no-op (just a FileManager.exists check).
    func installIfNeeded() {
        checkInstallation()
        guard !isInstalled else {
            print("[HelperInstaller] Helper already installed, no password needed")
            return
        }

        // Write helper script to a temp file
        let tempHelperScript = NSTemporaryDirectory() + "productivity-hosts-helper.sh"
        do {
            try helperScriptContent.write(toFile: tempHelperScript, atomically: true, encoding: .utf8)
        } catch {
            print("[HelperInstaller] Failed to write temp helper script: \(error)")
            return
        }

        let username = NSUserName()

        // Write the install script to a temp file (avoids AppleScript escaping issues)
        let installScript = """
        #!/bin/bash
        set -e
        cp '\(tempHelperScript)' '\(Self.helperPath)'
        chmod 755 '\(Self.helperPath)'
        chown root:wheel '\(Self.helperPath)'
        echo '\(username) ALL=(root) NOPASSWD: \(Self.helperPath)' > '\(Self.sudoersPath)'
        chmod 440 '\(Self.sudoersPath)'
        visudo -c -f '\(Self.sudoersPath)'
        rm -f '\(tempHelperScript)'
        echo 'INSTALLED'
        """

        let tempInstallScript = NSTemporaryDirectory() + "pt_install_helper.sh"
        do {
            try installScript.write(toFile: tempInstallScript, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tempInstallScript)
        } catch {
            print("[HelperInstaller] Failed to write install script: \(error)")
            try? FileManager.default.removeItem(atPath: tempHelperScript)
            return
        }

        // This is the ONE AND ONLY admin password prompt
        let appleScriptCode = "do shell script \"\(tempInstallScript)\" with administrator privileges"

        var errorInfo: NSDictionary?
        if let script = NSAppleScript(source: appleScriptCode) {
            let _ = script.executeAndReturnError(&errorInfo)
            if let error = errorInfo {
                print("[HelperInstaller] Installation failed (user may have cancelled): \(error)")
            } else {
                checkInstallation()
                if isInstalled {
                    print("[HelperInstaller] Helper installed — no more password prompts!")
                }
            }
        }

        // Clean up temp files (install script removes tempHelperScript on success)
        try? FileManager.default.removeItem(atPath: tempInstallScript)
        try? FileManager.default.removeItem(atPath: tempHelperScript)
    }

    // MARK: - Running the Helper

    /// Runs the installed helper script via sudo (passwordless thanks to sudoers entry).
    /// Returns (exitCode, stdout). Returns (-1, "") if the process couldn't be launched.
    func runHelper(arguments: [String]) -> (exitCode: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = [Self.helperPath] + arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
            process.waitUntilExit()
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return (process.terminationStatus, output)
        } catch {
            print("[HelperInstaller] Failed to run helper: \(error)")
            return (-1, "")
        }
    }
}
