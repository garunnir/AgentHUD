using System.ComponentModel;
using System.Media;
using System.Windows.Media;

namespace AgentHud;

// 표시 이름은 로컬라이징 테이블에서 가져오고 언어가 바뀌면 갱신
public sealed class SoundOption : INotifyPropertyChanged
{
    private readonly string _nameKey;
    public SoundOption(string key, string nameKey)
    {
        Key = key; _nameKey = nameKey;
        Loc.Instance.PropertyChanged += (_, _) => PropertyChanged?.Invoke(this, new(nameof(Name)));
    }
    public string Key { get; }
    public string Name => Loc.T(_nameKey);
    public event PropertyChangedEventHandler? PropertyChanged;
}

// 알림 사운드 선택. Key는 Off / 시스템 소리 이름 / File(사용자 지정 파일)
public static class SoundSetting
{
    public const string Off = "Off", File = "File";
    public static IReadOnlyList<SoundOption> Options { get; } =
    [
        new("Asterisk", "Sound.Asterisk"),
        new("Exclamation", "Sound.Exclamation"),
        new("Beep", "Sound.Beep"),
        new("Hand", "Sound.Hand"),
        new("Question", "Sound.Question"),
        new(File, "Sound.File"),
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
