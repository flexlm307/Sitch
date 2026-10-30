using System.IO;
using Windows.Globalization;
using Windows.Graphics.Imaging;
using Windows.Media.Ocr;
using Windows.Storage;
using Windows.Storage.Streams;

namespace Sitch.Shelf.Core;

/// <summary>
/// Reads the text in a screenshot. Default: the OCR built into Windows (no network, no service: the
/// engine the Snipping Tool uses). With Sitch's OcrEngine set to "RapidOCR" the external RapidOCR
/// worker reads it instead, falling back to Windows' engine (and saying why) when that fails.
/// </summary>
public static class Ocr
{
    private static bool UseRapid => App.Settings.OcrEngine == "RapidOCR";

    public static bool Available => UseRapid || OcrEngine.AvailableRecognizerLanguages.Count > 0;

    /// <returns>The recognised lines joined by new lines, empty if nothing was read, null if OCR is unavailable.</returns>
    public static async Task<string?> ReadAsync(string path)
    {
        if (UseRapid && await TryRapidAsync(path) is { } text) return text;
        var file = await StorageFile.GetFileFromPathAsync(path);
        using IRandomAccessStream stream = await file.OpenAsync(FileAccessMode.Read);
        return await ReadAsync(stream);
    }

    /// <summary>The editor's "Extract text": reads an in-memory image (encoded to PNG first).</summary>
    public static async Task<string?> ReadAsync(System.Windows.Media.Imaging.BitmapSource image)
    {
        var encoder = new System.Windows.Media.Imaging.PngBitmapEncoder();
        encoder.Frames.Add(System.Windows.Media.Imaging.BitmapFrame.Create(image));
        using var png = new MemoryStream();
        encoder.Save(png);

        if (UseRapid)
        {
            // The worker reads files, so the image takes a short trip through %TEMP%.
            var dir = Path.Combine(Path.GetTempPath(), "Sitch");
            Directory.CreateDirectory(dir);
            var tmp = Path.Combine(dir, $"ocr-{Guid.NewGuid():N}.png");
            try
            {
                await File.WriteAllBytesAsync(tmp, png.ToArray());
                if (await TryRapidAsync(tmp) is { } text) return text;
            }
            finally { try { File.Delete(tmp); } catch { } }
        }

        png.Position = 0;
        using var stream = png.AsRandomAccessStream();
        return await ReadAsync(stream);
    }

    private static async Task<string?> TryRapidAsync(string path)
    {
        try { return await RapidOcr.ReadAsync(path); }
        catch (Exception e)
        {
            Log.Error($"RapidOCR failed: {e.Message}");
            global::Sitch.Shell.NotifyPopup.Show(global::Sitch.Shell.Loc.F("RapidOCR failed, using Windows OCR: {0}", e.Message));
            return null;
        }
    }

    private static async Task<string?> ReadAsync(IRandomAccessStream stream)
    {
        var engine = OcrEngine.TryCreateFromUserProfileLanguages()
            ?? OcrEngine.TryCreateFromLanguage(new Language("en-US"))
            ?? (OcrEngine.AvailableRecognizerLanguages.FirstOrDefault() is { } first ? OcrEngine.TryCreateFromLanguage(first) : null);
        if (engine is null) return null;

        var decoder = await BitmapDecoder.CreateAsync(stream);

        // The engine has a size limit; large captures are scaled to fit it.
        uint max = OcrEngine.MaxImageDimension;
        var transform = new BitmapTransform();
        if (decoder.PixelWidth > max || decoder.PixelHeight > max)
        {
            double scale = Math.Min((double)max / decoder.PixelWidth, (double)max / decoder.PixelHeight);
            transform.ScaledWidth = (uint)Math.Max(1, decoder.PixelWidth * scale);
            transform.ScaledHeight = (uint)Math.Max(1, decoder.PixelHeight * scale);
            transform.InterpolationMode = BitmapInterpolationMode.Fant;
        }
        using var bitmap = await decoder.GetSoftwareBitmapAsync(
            BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied, transform,
            ExifOrientationMode.RespectExifOrientation, ColorManagementMode.DoNotColorManage);

        var text = await RecognizeAsync(engine, bitmap);

        // A CJK engine mangles Latin text ("Perf0 rm a nce", full-width punctuation). When it finds
        // almost no CJK characters, a Latin-script engine (if one is installed) reads the image again.
        if (IsCjk(engine.RecognizerLanguage) && CjkShare(text) < 0.1
            && OcrEngine.AvailableRecognizerLanguages.FirstOrDefault(l => !IsCjk(l)) is { } latin
            && OcrEngine.TryCreateFromLanguage(latin) is { } latinEngine)
        {
            var latinText = await RecognizeAsync(latinEngine, bitmap);
            if (latinText.Length > 0) text = latinText;
        }
        return text;
    }

    private static async Task<string> RecognizeAsync(OcrEngine engine, SoftwareBitmap bitmap)
    {
        var result = await engine.RecognizeAsync(bitmap);
        var lines = result.Lines.Select(l => l.Text.Trim()).Where(t => t.Length > 0);
        return string.Join(Environment.NewLine, lines);
    }

    private static bool IsCjk(Language language) =>
        language.LanguageTag.Split('-')[0] is "zh" or "ja" or "ko";

    private static double CjkShare(string text)
    {
        int letters = 0, cjk = 0;
        foreach (char ch in text)
        {
            if (!char.IsLetter(ch)) continue;
            letters++;
            if (ch is >= '぀' and <= 'ヿ' or >= '㐀' and <= '鿿' or >= '가' and <= '힯') cjk++;
        }
        return letters == 0 ? 0 : (double)cjk / letters;
    }
}
