using System.Media;
using System.Windows.Media;

namespace AgentHud;

public sealed record SoundOption(string Key, string Name);

// 알림 사운드 선택. Key는 Off / 시스템 소리 이름 / File(사용자 지정 파일)
public static class SoundSetting
{
    public const string Off = "Off", File = "File";
    public static IReadOnlyList<SoundOption> Options { get; } =
    [
        new("Asterisk", "Windows 알림 (Asterisk)"),
        new("Exclamation", "Windows 경고 (Exclamation)"),
        new("Beep", "Windows 비프 (Beep)"),
        new("Hand", "Windows 오류 (Hand)"),
        new("Question", "Windows 질문 (Question)"),
        new(File, "사용자 파일 (wav·mp3)"),
    ];
    // MediaPlayer는 재생 중 GC되면 멈추므로 참조 유지
    private static MediaPlayer? _filePlayer;

    public static void Play(string key, string? filePath)
    {
        try
        {
            switch (key)
            {
                case Off: return;
                case File:
                    if (string.IsNullOrWhiteSpace(filePath) || !System.IO.File.Exists(filePath)) return;
                    _filePlayer?.Close();
                    _filePlayer = new MediaPlayer();
                    _filePlayer.Open(new Uri(filePath));
                    _filePlayer.Play();
                    return;
                case "Asterisk": SystemSounds.Asterisk.Play(); return;
                case "Exclamation": SystemSounds.Exclamation.Play(); return;
                case "Hand": SystemSounds.Hand.Play(); return;
                case "Question": SystemSounds.Question.Play(); return;
                default: SystemSounds.Beep.Play(); return;
            }
        }
        catch { }
    }
}
