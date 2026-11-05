using System.Globalization;
using System.Net;
using System.Net.Sockets;

namespace AgentHud;

// 깨어 있을 때 받은 WoL 매직패킷(FF×6 + MAC×16 [+ SecureOn 비밀번호 4·6바이트])을 감지.
// 절전 중에는 NIC가 하드웨어로 처리해 OS에 패킷이 오지 않으므로, 깨운 뒤 한 번 더 보낸 패킷으로 동작한다
public sealed class MagicPacketListener : IDisposable
{
    private readonly UdpClient _client;
    private readonly CancellationTokenSource _stop = new();
    private readonly IReadOnlyList<byte[]> _macs;
    private readonly byte[]? _password;
    public event Action? Received;

    /// <summary>포트를 열지 못하면 SocketException</summary>
    public MagicPacketListener(int port, IReadOnlyList<byte[]> macs, byte[]? password)
    {
        _macs = macs; _password = password;
        _client = new UdpClient(AddressFamily.InterNetwork) { ExclusiveAddressUse = false };
        // 다른 WoL 도구가 같은 포트를 듣고 있어도 같이 받도록 공유
        _client.Client.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true);
        _client.Client.Bind(new IPEndPoint(IPAddress.Any, port));
        _ = Task.Run(LoopAsync);
    }

    private async Task LoopAsync()
    {
        while (!_stop.IsCancellationRequested)
        {
            try
            {
                var result = await _client.ReceiveAsync(_stop.Token);
                if (IsMagicPacket(result.Buffer, _macs, _password)) Received?.Invoke();
            }
            catch (OperationCanceledException) { return; }
            catch (ObjectDisposedException) { return; }
            // ICMP port unreachable 등 개별 수신 오류는 무시하고 계속 듣는다
            catch (SocketException) { }
        }
    }

    public static bool IsMagicPacket(ReadOnlySpan<byte> data, IEnumerable<byte[]> macs, byte[]? password = null)
    {
        foreach (var mac in macs)
        {
            if (mac.Length != 6) continue;
            for (var start = 0; start + 102 <= data.Length; start++)
            {
                if (!Matches(data[start..], mac)) continue;
                if (password is not { Length: > 0 }) return true;
                if (start + 102 + password.Length <= data.Length && data.Slice(start + 102, password.Length).SequenceEqual(password)) return true;
            }
        }
        return false;
    }

    private static bool Matches(ReadOnlySpan<byte> data, byte[] mac)
    {
        for (var i = 0; i < 6; i++) if (data[i] != 0xFF) return false;
        for (var i = 0; i < 16; i++) if (!data.Slice(6 + i * 6, 6).SequenceEqual(mac)) return false;
        return true;
    }

    /// <summary>"01-23-45-67-89-AB", "01:23:45:67", "0123456789AB" 형식. 빈 값이면 비밀번호 없음(null)으로 true, 형식이 틀리면 false</summary>
    public static bool TryParsePassword(string? text, out byte[]? password)
    {
        password = null;
        var hex = new string((text ?? "").Where(c => c is not ('-' or ':' or ' ')).ToArray());
        if (hex.Length == 0) return true;
        if (hex.Length is not (8 or 12)) return false;
        var bytes = new byte[hex.Length / 2];
        for (var i = 0; i < bytes.Length; i++)
            if (!byte.TryParse(hex.AsSpan(i * 2, 2), NumberStyles.HexNumber, CultureInfo.InvariantCulture, out bytes[i])) return false;
        password = bytes;
        return true;
    }

    public void Dispose()
    {
        _stop.Cancel();
        _client.Dispose();
        _stop.Dispose();
    }
}
