using System.Text;

namespace AgentHud.Discovery;

internal static class SessionFileReader
{
    public static async Task<string?> ReadFirstLineAsync(string path, CancellationToken token)
    {
        try
        {
            await using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete, 4096, true);
            using var reader = new StreamReader(stream, Encoding.UTF8);
            return await reader.ReadLineAsync(token);
        }
        catch (IOException) { return null; }
        catch (UnauthorizedAccessException) { return null; }
    }
}
