using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text.Json;

namespace Perch.Windows;

public sealed record InsightsWindow(int Days, string? Start, string? End, DateTimeOffset? StartDate, DateTimeOffset? EndDate);

public sealed record InsightsTotals(int Sessions, int? Subagents, int? ActiveDays, double? CacheHitRate, double? ErrorRate);

public sealed record InsightsAgent(string Id, string Name, string? Role, int Sessions, int? Subagents, double? CacheHitRate, double? ErrorRate);

public sealed record InsightsDelta(string? ComparedTo, DateTimeOffset? ComparedToDate, int? Sessions, double? CacheHitRate, double? ErrorRate);

/// Read-only aggregate summary exported by omni-insights (`<root>/insights/summary.json`).
public sealed record InsightsSummary(
    int Version,
    DateTimeOffset GeneratedAt,
    InsightsWindow Window,
    string? ReportPath,
    InsightsTotals Totals,
    IReadOnlyList<InsightsAgent> Agents,
    InsightsDelta? Delta)
{
    public const int SupportedVersion = 1;

    public string? ValidateReportPath(string? home = null) => ValidateReportPath(ReportPath, home);

    public static InsightsSummary? Parse(ReadOnlySpan<byte> utf8Json)
    {
        try
        {
            using var doc = JsonDocument.Parse(utf8Json.ToArray());
            var root = doc.RootElement;
            if (root.ValueKind != JsonValueKind.Object)
                return null;

            if (!TryGetInt(root, "version", out var version) || version != SupportedVersion)
                return null;

            var generatedAtRaw = TryGetString(root, "generatedAt");
            if (generatedAtRaw == null || !TryParseTimestamp(generatedAtRaw, out var generatedAt))
                return null;

            if (!root.TryGetProperty("window", out var windowEl) || windowEl.ValueKind != JsonValueKind.Object)
                return null;
            if (!TryGetInt(windowEl, "days", out var days) || days < 0)
                return null;

            var start = TryGetString(windowEl, "start");
            var end = TryGetString(windowEl, "end");
            var window = new InsightsWindow(
                days,
                start,
                end,
                start != null && TryParseTimestamp(start, out var startDate) ? startDate : null,
                end != null && TryParseTimestamp(end, out var endDate) ? endDate : null);

            if (!root.TryGetProperty("totals", out var totalsEl) || totalsEl.ValueKind != JsonValueKind.Object)
                return null;
            if (!TryGetInt(totalsEl, "sessions", out var sessions) || sessions < 0)
                return null;

            var totals = new InsightsTotals(
                sessions,
                TryGetOptionalInt(totalsEl, "subagents"),
                TryGetOptionalInt(totalsEl, "activeDays"),
                TryGetOptionalDouble(totalsEl, "cacheHitRate"),
                TryGetOptionalDouble(totalsEl, "errorRate"));

            var reportPath = TryGetString(root, "reportPath");

            var agents = new List<InsightsAgent>();
            if (root.TryGetProperty("agents", out var agentsEl) && agentsEl.ValueKind != JsonValueKind.Null)
            {
                if (agentsEl.ValueKind != JsonValueKind.Array)
                    return null;
                foreach (var item in agentsEl.EnumerateArray())
                {
                    if (item.ValueKind != JsonValueKind.Object)
                        continue;
                    var id = TryGetString(item, "id");
                    var name = TryGetString(item, "name");
                    if (id == null || name == null || !TryGetInt(item, "sessions", out var agentSessions) || agentSessions < 0)
                        continue;
                    agents.Add(new InsightsAgent(
                        id,
                        name,
                        TryGetString(item, "role"),
                        agentSessions,
                        TryGetOptionalInt(item, "subagents"),
                        TryGetOptionalDouble(item, "cacheHitRate"),
                        TryGetOptionalDouble(item, "errorRate")));
                }
            }

            InsightsDelta? delta = null;
            if (root.TryGetProperty("delta", out var deltaEl) && deltaEl.ValueKind != JsonValueKind.Null)
            {
                if (deltaEl.ValueKind != JsonValueKind.Object)
                    return null;
                var comparedTo = TryGetString(deltaEl, "comparedTo");
                delta = new InsightsDelta(
                    comparedTo,
                    comparedTo != null && TryParseTimestamp(comparedTo, out var comparedToDate) ? comparedToDate : null,
                    TryGetOptionalInt(deltaEl, "sessions"),
                    TryGetOptionalDouble(deltaEl, "cacheHitRate"),
                    TryGetOptionalDouble(deltaEl, "errorRate"));
            }

            return new InsightsSummary(version, generatedAt, window, reportPath, totals, agents, delta);
        }
        catch
        {
            return null;
        }
    }

    public static bool TryParseTimestamp(string value, out DateTimeOffset result)
    {
        var trimmed = value.Trim();
        if (trimmed.Length == 10 &&
            DateOnly.TryParseExact(trimmed, "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out var dateOnly))
        {
            result = new DateTimeOffset(dateOnly.ToDateTime(TimeOnly.MinValue, DateTimeKind.Utc));
            return true;
        }

        return DateTimeOffset.TryParse(
            trimmed,
            CultureInfo.InvariantCulture,
            DateTimeStyles.RoundtripKind,
            out result);
    }

    /// Validates `reportPath`: expands leading `~/` or `~\`, resolves symlinks/junctions,
    /// requires the canonical target to be a regular `.html`/`.htm` file strictly inside `home`.
    public static string? ValidateReportPath(string? rawPath, string? home = null)
    {
        if (string.IsNullOrWhiteSpace(rawPath))
            return null;

        var trimmed = rawPath.Trim();
        var userHome = string.IsNullOrWhiteSpace(home)
            ? Environment.GetFolderPath(Environment.SpecialFolder.UserProfile)
            : home.Trim();
        if (string.IsNullOrWhiteSpace(userHome))
            return null;

        string expanded;
        if (trimmed == "~")
        {
            expanded = userHome;
        }
        else if (trimmed.StartsWith("~/", StringComparison.Ordinal) || trimmed.StartsWith(@"~\", StringComparison.Ordinal))
        {
            expanded = Path.Combine(userHome, trimmed[2..]);
        }
        else if (trimmed.StartsWith("~", StringComparison.Ordinal))
        {
            return null;
        }
        else
        {
            expanded = trimmed;
        }

        if (!Path.IsPathFullyQualified(expanded))
            return null;

        var canonicalHome = ResolveCanonicalPath(userHome, mustBeFile: false);
        var canonicalTarget = ResolveCanonicalPath(expanded, mustBeFile: true);
        if (canonicalHome == null || canonicalTarget == null)
            return null;

        var sep = Path.DirectorySeparatorChar;
        var homePrefix = canonicalHome.EndsWith(sep) ? canonicalHome : canonicalHome + sep;
        var comparison = OperatingSystem.IsLinux() ? StringComparison.Ordinal : StringComparison.OrdinalIgnoreCase;
        if (!canonicalTarget.StartsWith(homePrefix, comparison))
            return null;

        var ext = Path.GetExtension(canonicalTarget);
        if (!string.Equals(ext, ".html", StringComparison.OrdinalIgnoreCase) &&
            !string.Equals(ext, ".htm", StringComparison.OrdinalIgnoreCase))
            return null;

        return canonicalTarget;
    }

    private static string? ResolveCanonicalPath(string path, bool mustBeFile)
    {
        try
        {
            var current = Path.GetFullPath(path);
            if (mustBeFile)
            {
                if (!File.Exists(current))
                    return null;
            }
            else if (!Directory.Exists(current))
            {
                return null;
            }

            for (int pass = 0; pass < 8; pass++)
            {
                var root = Path.GetPathRoot(current);
                if (string.IsNullOrEmpty(root))
                    return null;

                var remainder = current[root.Length..];
                var parts = remainder.Split(
                    [Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar],
                    StringSplitOptions.RemoveEmptyEntries);

                var built = root;
                bool changed = false;
                for (int i = 0; i < parts.Length; i++)
                {
                    built = Path.Combine(built, parts[i]);
                    bool isLast = i == parts.Length - 1;
                    FileSystemInfo? target = null;
                    if (isLast && mustBeFile)
                    {
                        var fi = new FileInfo(built);
                        if (fi.LinkTarget != null)
                            target = fi.ResolveLinkTarget(returnFinalTarget: true);
                    }
                    else
                    {
                        var di = new DirectoryInfo(built);
                        if (di.LinkTarget != null)
                            target = di.ResolveLinkTarget(returnFinalTarget: true);
                    }

                    if (target != null)
                    {
                        var rest = i + 1 < parts.Length ? Path.Combine(parts[(i + 1)..]) : "";
                        var next = string.IsNullOrEmpty(rest)
                            ? Path.GetFullPath(target.FullName)
                            : Path.GetFullPath(Path.Combine(target.FullName, rest));
                        if (!string.Equals(next, current, StringComparison.Ordinal))
                        {
                            current = next;
                            changed = true;
                            break;
                        }
                    }
                }

                if (!changed)
                    break;
            }

            if (mustBeFile)
            {
                if (!File.Exists(current))
                    return null;
                var attrs = File.GetAttributes(current);
                if ((attrs & FileAttributes.Directory) != 0)
                    return null;
                return current;
            }

            return Directory.Exists(current) ? current : null;
        }
        catch
        {
            return null;
        }
    }

    private static bool TryGetInt(JsonElement obj, string key, out int value)
    {
        value = 0;
        return obj.TryGetProperty(key, out var el) && el.ValueKind == JsonValueKind.Number && el.TryGetInt32(out value);
    }

    private static int? TryGetOptionalInt(JsonElement obj, string key)
    {
        if (!obj.TryGetProperty(key, out var el) || el.ValueKind != JsonValueKind.Number)
            return null;
        return el.TryGetInt32(out var value) ? value : null;
    }

    private static double? TryGetOptionalDouble(JsonElement obj, string key)
    {
        if (!obj.TryGetProperty(key, out var el) || el.ValueKind != JsonValueKind.Number)
            return null;
        return el.TryGetDouble(out var value) && double.IsFinite(value) ? value : null;
    }

    private static string? TryGetString(JsonElement obj, string key)
    {
        if (!obj.TryGetProperty(key, out var el) || el.ValueKind != JsonValueKind.String)
            return null;
        var text = el.GetString()?.Trim();
        return string.IsNullOrEmpty(text) ? null : text;
    }
}

/// Passive, bounded (256 KB), mtime+size-cached reader for `<root>/insights/summary.json`.
public sealed class InsightsSummaryReader
{
    public const long MaxBytes = 256 * 1024;

    private readonly object gate = new();
    private (DateTime ModifiedUtc, long Size)? cachedStamp;
    private InsightsSummary? cachedSummary;

    public string FilePath { get; }

    /// Exposed for unit tests to verify cache hits skip disk reads.
    public int ReadCount { get; private set; }

    public InsightsSummaryReader(string root)
        : this(Path.Combine(root, "insights", "summary.json"), directFile: true)
    {
    }

    private InsightsSummaryReader(string filePath, bool directFile)
    {
        _ = directFile;
        FilePath = filePath;
    }

    public static InsightsSummaryReader FromFile(string filePath) => new(filePath, directFile: true);

    public InsightsSummary? Read()
    {
        lock (gate)
        {
            try
            {
                var info = new FileInfo(FilePath);
                if (!info.Exists)
                {
                    Clear();
                    return null;
                }

                if (info.LinkTarget != null)
                {
                    if (info.ResolveLinkTarget(returnFinalTarget: true) is FileInfo target && target.Exists)
                        info = target;
                    else
                    {
                        Clear();
                        return null;
                    }
                }

                if ((info.Attributes & FileAttributes.Directory) != 0)
                {
                    Clear();
                    return null;
                }

                var size = info.Length;
                if (size < 0 || size > MaxBytes)
                {
                    Clear();
                    return null;
                }

                var stamp = (info.LastWriteTimeUtc, size);
                if (cachedStamp.HasValue && cachedStamp.Value == stamp)
                    return cachedSummary;

                ReadCount++;
                var bytes = File.ReadAllBytes(info.FullName);
                if (bytes.Length > MaxBytes)
                {
                    Clear();
                    return null;
                }

                var parsed = InsightsSummary.Parse(bytes);
                cachedStamp = stamp;
                cachedSummary = parsed;
                return parsed;
            }
            catch
            {
                Clear();
                return null;
            }
        }
    }

    private void Clear()
    {
        cachedStamp = null;
        cachedSummary = null;
    }
}
