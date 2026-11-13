using System;
using System.IO;
using System.Linq;
using System.Collections.Generic;
using System.Runtime.CompilerServices;
using System.Text.Json;
using Perch.Windows;

internal static class PetDialogueTests
{
    public static void Run([CallerFilePath] string source = "")
    {
        var path = Path.GetFullPath(Path.Combine(Path.GetDirectoryName(source)!, "../../../shared/strings/zh-CN.json"));
        var expected = JsonSerializer.Deserialize<Dictionary<string, string>>(File.ReadAllText(path))!;
        Check(Strings.All.Count == expected.Count && expected.All(p => Strings.Get(p.Key) == p.Value), "Embedded strings must match the canonical shared JSON");
        foreach (string? character in new string?[] { "deepseek-whale", "pox", "native", "removed-character", null })
        {
            var prefix = character == "deepseek-whale" ? "pet.whale." : "pet.";
            for (int pose = 0; pose < 8; pose++)
                Check(PetCharacters.PoseLabel(character, pose) == expected[prefix + "pose." + pose], "Pose dialogue stays in the selected character namespace");
            foreach (var key in new[] { "moved", "doubleClick", "completion", "running", "media" })
            {
                Check(PetCharacters.DialogueKey(character, key) == prefix + key, "Only whale selects whale keys");
                Check(PetCharacters.Feedback(character, key) == expected[prefix + key], "Feedback is read from JSON");
            }
        }
        Check(Strings.Format("pet.preview.detail", "测试 ♡ {name}") == expected["pet.preview.detail"].Replace("{0}", "测试 ♡ {name}"), "Formatting preserves Unicode and literal braces in arguments");
        Console.WriteLine("PASS: shared JSON embedding, pet dialogue namespaces and placeholder formatting");
    }

    private static void Check(bool value, string message)
    {
        if (!value) throw new Exception(message);
    }
}
