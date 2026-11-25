using System;
using System.IO;
using System.Linq;
using System.Text;
using Perch.Windows;

internal static class InsightsSummaryTests
{
    private static void Check(bool condition, string message)
    {
        if (!condition)
            throw new Exception(message);
    }

    public static void Run(string root)
    {
        TestValidSchemaAndDateOnlyWindow();
        TestMinimalForwardCompatibleSchema();
        TestSharedFixture();
        TestDegradesWhenMissingMalformedOrUnsupported(root);
        TestRejectsOversizedSummary(root);
        TestPathValidation(root);
        TestCachesByMtimeAndFileSize(root);
        Console.WriteLine("PASS: insights summary schema, size cap, mtime cache and path safety");
    }

    private static void TestValidSchemaAndDateOnlyWindow()
    {
        const string json = """
        {
          "version": 1,
          "generatedAt": "2026-11-24T23:48:54.171960+08:00",
          "window": { "days": 30, "start": "2026-10-16", "end": "2026-11-24" },
          "reportPath": "/Users/demo/.agents/omni-insights/latest.html",
          "totals": { "sessions": 198, "subagents": 502, "activeDays": 35, "cacheHitRate": 0.983, "errorRate": 0.023 },
          "agents": [
            { "id": "codex", "name": "Codex", "role": "active", "sessions": 45, "subagents": 1, "cacheHitRate": 0.98, "errorRate": 0.056 },
            { "id": "claude", "name": "Claude", "role": "historical", "sessions": 146 }
          ],
          "delta": { "comparedTo": "2026-11-24T23:48:51.692243+08:00", "sessions": 5, "cacheHitRate": 0.012, "errorRate": -0.003 }
        }
        """;
        var summary = InsightsSummary.Parse(Encoding.UTF8.GetBytes(json));
        Check(summary != null, "Valid insights summary with microseconds and YYYY-MM-DD must parse");
        Check(summary!.Version == 1 && summary.Window.Days == 30, "Version and window days");
        Check(summary.Window.Start == "2026-10-16" && summary.Window.StartDate != null, "YYYY-MM-DD start must parse");
        Check(summary.Window.End == "2026-11-24" && summary.Window.EndDate != null, "YYYY-MM-DD end must parse");
        Check(summary.Totals.Sessions == 198 && summary.Totals.Subagents == 502 && summary.Totals.ActiveDays == 35, "Totals fields");
        Check(summary.Agents.Count == 2 && summary.Agents[0].Id == "codex" && summary.Agents[1].Subagents == null, "Optional agent fields");
        Check(summary.Delta?.Sessions == 5 && summary.Delta?.ComparedToDate != null, "Delta fields");
    }

    private static void TestMinimalForwardCompatibleSchema()
    {
        const string json = """
        {
          "version": 1,
          "generatedAt": "2026-11-24T15:48:54Z",
          "window": { "days": 7, "start": "2026-11-17T00:00:00Z", "end": "2026-11-24T00:00:00Z" },
          "totals": { "sessions": 12 }
        }
        """;
        var summary = InsightsSummary.Parse(Encoding.UTF8.GetBytes(json));
        Check(summary != null, "Minimal schema without optional fields must parse");
        Check(summary!.ReportPath == null && summary.Agents.Count == 0 && summary.Delta == null, "Omitted optional fields default cleanly");
        Check(summary.Totals.Subagents == null && summary.Totals.CacheHitRate == null && summary.Totals.ErrorRate == null, "Omitted totals metrics stay null");
    }

    private static void TestSharedFixture()
    {
        var fixture = Path.Combine(AppContext.BaseDirectory, "fixtures", "insights", "summary.json");
        var reader = InsightsSummaryReader.FromFile(fixture);
        var summary = reader.Read();
        Check(summary != null, "Shared insights fixture must parse");
        Check(summary!.Totals.Sessions == 198 && summary.Agents.Select(a => a.Id).SequenceEqual(["codex", "antigravity", "claude"]), "Shared fixture content");
        Check(summary.Delta?.Sessions == 12, "Shared fixture delta");
    }

    private static void TestDegradesWhenMissingMalformedOrUnsupported(string root)
    {
        var dir = Path.Combine(root, "insights-degrade");
        var reader = new InsightsSummaryReader(dir);
        Check(reader.Read() == null && reader.ReadCount == 0, "Missing summary must return null without reading");

        var insightsDir = Path.Combine(dir, "insights");
        Directory.CreateDirectory(insightsDir);
        var file = Path.Combine(insightsDir, "summary.json");

        File.WriteAllText(file, """{"version":2,"generatedAt":"2026-11-24T15:48:54Z","window":{"days":30},"totals":{"sessions":1}}""");
        Check(reader.Read() == null, "Unsupported version must return null");

        File.WriteAllText(file, "{broken");
        Check(reader.Read() == null, "Malformed JSON must return null");

        File.WriteAllText(file, """{"version":1,"generatedAt":"2026-11-24T15:48:54Z","window":{"days":30},"totals":{"sessions":9}}""");
        Check(reader.Read()?.Totals.Sessions == 9, "Valid file must load");

        File.Delete(file);
        Check(reader.Read() == null, "Deleting file must clear cache and return null");
    }

    private static void TestRejectsOversizedSummary(string root)
    {
        var dir = Path.Combine(root, "insights-oversized");
        var insightsDir = Path.Combine(dir, "insights");
        Directory.CreateDirectory(insightsDir);
        var file = Path.Combine(insightsDir, "summary.json");

        var pad = new string('a', (int)InsightsSummaryReader.MaxBytes + 128);
        File.WriteAllText(file, "{\"version\":1,\"generatedAt\":\"2026-11-24T15:48:54Z\",\"window\":{\"days\":30},\"reportPath\":\"" + pad + "\",\"totals\":{\"sessions\":1}}");

        var reader = new InsightsSummaryReader(dir);
        Check(reader.Read() == null && reader.ReadCount == 0, "Files over 256 KB must be rejected before reading");
    }

    private static void TestPathValidation(string root)
    {
        var sandbox = Path.Combine(root, "insights-paths");
        var home = Path.Combine(sandbox, "home");
        var sibling = Path.Combine(sandbox, "home2");
        var outside = Path.Combine(sandbox, "outside");
        var agentsDir = Path.Combine(home, ".agents");
        Directory.CreateDirectory(agentsDir);
        Directory.CreateDirectory(sibling);
        Directory.CreateDirectory(outside);

        var validHtml = Path.Combine(agentsDir, "latest.html");
        var validHtm = Path.Combine(agentsDir, "alt.HTM");
        var nonHtml = Path.Combine(agentsDir, "run.cmd");
        var dirHtml = Path.Combine(agentsDir, "folder.html");
        var siblingHtml = Path.Combine(sibling, "report.html");
        var outsideHtml = Path.Combine(outside, "secret.html");

        File.WriteAllText(validHtml, "<html/>");
        File.WriteAllText(validHtm, "<html/>");
        File.WriteAllText(nonHtml, "echo hi");
        Directory.CreateDirectory(dirHtml);
        File.WriteAllText(siblingHtml, "<html/>");
        File.WriteAllText(outsideHtml, "<html/>");

        Check(InsightsSummary.ValidateReportPath(validHtml, home) != null, "Valid .html inside home must pass");
        Check(InsightsSummary.ValidateReportPath("~/.agents/latest.html", home) != null, "Tilde path inside home must pass");
        Check(InsightsSummary.ValidateReportPath(validHtm, home) != null, "Valid .HTM inside home must pass");

        Check(InsightsSummary.ValidateReportPath(nonHtml, home) == null, "Non-html file must be rejected");
        Check(InsightsSummary.ValidateReportPath(dirHtml, home) == null, "Directory named .html must be rejected");
        Check(InsightsSummary.ValidateReportPath("latest.html", home) == null, "Relative path must be rejected");
        Check(InsightsSummary.ValidateReportPath("~other/.agents/latest.html", home) == null, "Other-user tilde path must be rejected");
        Check(InsightsSummary.ValidateReportPath(outsideHtml, home) == null, "Path outside home must be rejected");
        Check(InsightsSummary.ValidateReportPath(siblingHtml, home) == null, "Sibling home prefix path must be rejected");

        // Symlink tests (skipped only if OS disallows unprivileged symlink creation)
        var escapeLink = Path.Combine(agentsDir, "escape.html");
        var disguisedLink = Path.Combine(agentsDir, "disguised.html");
        bool createdSymlink = false;
        try
        {
            File.CreateSymbolicLink(escapeLink, outsideHtml);
            File.CreateSymbolicLink(disguisedLink, nonHtml);
            createdSymlink = true;
        }
        catch (UnauthorizedAccessException)
        {
        }
        catch (IOException)
        {
        }

        if (createdSymlink)
        {
            Check(InsightsSummary.ValidateReportPath(escapeLink, home) == null, "Symlink escaping home must be rejected");
            Check(InsightsSummary.ValidateReportPath(disguisedLink, home) == null, "Symlink to non-html must be rejected");
        }
    }

    private static void TestCachesByMtimeAndFileSize(string root)
    {
        var dir = Path.Combine(root, "insights-cache");
        var insightsDir = Path.Combine(dir, "insights");
        Directory.CreateDirectory(insightsDir);
        var file = Path.Combine(insightsDir, "summary.json");

        File.WriteAllText(file, """{"version":1,"generatedAt":"2026-11-24T15:48:54Z","window":{"days":30},"totals":{"sessions":10}}""");
        var reader = new InsightsSummaryReader(dir);
        Check(reader.Read()?.Totals.Sessions == 10 && reader.ReadCount == 1, "First read parses from disk");
        Check(reader.Read()?.Totals.Sessions == 10 && reader.ReadCount == 1, "Second read hits mtime+size cache");

        File.WriteAllText(file, """{"version":1,"generatedAt":"2026-11-24T16:48:54Z","window":{"days":30},"totals":{"sessions":123}}""");
        File.SetLastWriteTimeUtc(file, DateTime.UtcNow.AddSeconds(5));
        Check(reader.Read()?.Totals.Sessions == 123 && reader.ReadCount == 2, "Updated file invalidates cache");
    }
}
