import Foundation

/// Reading an application's identity out of the path of one of its processes.
///
/// Lives here rather than beside `BundleIdentifierResolver` because the rule and the lookup are
/// different things: *which* bundle owns a process is pure path arithmetic and worth pinning with
/// tests, while reading that bundle's identifier needs the file system and a live pid. Constraint
/// D1 records why the rule matters — it was a real bug, not a tidy-up.
public enum ExecutablePath {
    /// The outermost `.app` enclosing an executable, or nil when the path is not inside one.
    ///
    /// Outermost, not nearest, and that is the entire point. An application's helpers are often
    /// registered `.app` bundles in their own right — Teams' WebView helper is one — so stopping at
    /// the first bundle found while walking upwards returns the helper and defeats the
    /// normalisation. Grouping evidence by subject then makes one meeting look like several.
    public static func outermostApplicationBundle(forExecutableAt path: String) -> URL? {
        guard !path.isEmpty else { return nil }
        var url = URL(fileURLWithPath: path)
        var outermost: URL?
        // Walking up and keeping the last match found is what makes this outermost rather than
        // nearest: each step overwrites a deeper bundle with the shallower one enclosing it.
        while url.pathComponents.count > 1 {
            if url.pathExtension == "app" { outermost = url }
            url = url.deletingLastPathComponent()
        }
        return outermost
    }
}
