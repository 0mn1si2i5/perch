namespace Perch.Windows;

public static class PetCharacters
{
    public static string Normalize(string? character) => character is "pox" or "deepseek-whale" ? character : "native";
    public static bool UsesSprites(string? character) => Normalize(character) != "native";
    public static string Title(string? character) => Normalize(character) switch
    {
        "pox" => "Pox",
        "deepseek-whale" => "DeepSeek 鲸鱼娘",
        _ => "原生浮球"
    };

    // Only the whale opts into character dialogue; shared Pox/orb strings stay intact.
    public static string PoseLabel(string? character, int pose) =>
        Strings.Get((character == "deepseek-whale" ? "pet.whale.pose." : "pet.pose.") + pose);

    public static string Feedback(string? character, string key, string fallback) =>
        character == "deepseek-whale" ? Strings.Get("pet.whale." + key) : fallback;
}
