import Foundation

/// Where command-line tools the owner installed usually live. Apps opened from Finder start with a short
/// PATH, so these are searched as well as PATH, and added to PATH for terminal providers.
public enum ToolPaths {
    public static func userDirectories(home: String = NSHomeDirectory()) -> [String] {
        [home + "/.local/bin", home + "/.npm-global/bin", home + "/.bun/bin", "/opt/homebrew/bin", "/usr/local/bin"]
    }
}
