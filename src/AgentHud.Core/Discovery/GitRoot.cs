namespace AgentHud.Discovery;

internal static class GitRoot
{
    public static string? Find(string? path)
    {
        if (string.IsNullOrWhiteSpace(path)) return null;
        try
        {
            for (var dir = new DirectoryInfo(path); dir is not null; dir = dir.Parent)
                if (Directory.Exists(Path.Combine(dir.FullName, ".git")) || File.Exists(Path.Combine(dir.FullName, ".git"))) return dir.FullName;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or ArgumentException) { }
        return null;
    }
}
