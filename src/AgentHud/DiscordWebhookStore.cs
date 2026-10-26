using System.Security.Cryptography;
using System.Text;

namespace AgentHud;

// 웹훅 URL은 비밀이라 claude-session.bin처럼 DPAPI(현재 사용자)로 암호화해 저장
public static class DiscordWebhookStore
{
    private static string FilePath => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "AgentHud", "discord-webhook.bin");
    public static bool Exists => File.Exists(FilePath);
    public static string? Load()
    {
        try { return File.Exists(FilePath) ? Encoding.UTF8.GetString(ProtectedData.Unprotect(File.ReadAllBytes(FilePath), null, DataProtectionScope.CurrentUser)) : null; }
        catch (Exception e) when (e is CryptographicException or IOException) { return null; }
    }
    public static void Save(string? url)
    {
        if (string.IsNullOrWhiteSpace(url)) { try { File.Delete(FilePath); } catch (IOException) { } return; }
        Directory.CreateDirectory(Path.GetDirectoryName(FilePath)!);
        File.WriteAllBytes(FilePath, ProtectedData.Protect(Encoding.UTF8.GetBytes(url.Trim()), null, DataProtectionScope.CurrentUser));
    }
}
