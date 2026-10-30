using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace Sitch.Capture;

/// <summary>What one frame did to the long image.</summary>
public enum StitchStep { Unchanged, Appended, NoMatch, Full }

/// <summary>
/// Joins frames of a region the user scrolls into one tall image (approach after evan's ScrollStitcher,
/// MIT). Frames are Bgr32 rows of the same width and height. Each new frame is matched against the
/// previous one: rows that stay put at the top (a sticky header) or bottom (a footer, a status bar) are
/// found first and left out of the match, so they appear once instead of in every slice; the scrolling
/// middle is matched coarsely on per-row signatures, then confirmed on full pixels. Only downward
/// scrolling extends the image.
/// </summary>
public sealed class ScrollStitcher
{
    public const int MaxHeight = 30000;

    private const int SigColumns = 64;      // per-row signature: average luminance of 64 column bands
    private const double StaticRow = 0.5;   // mean |Δ| per pixel channel under which a row "didn't move"
    private const double StillFrame = 2.0;  // whole-frame mean |Δ| under which nothing scrolled
    private const double MatchLimit = 10.0; // full-pixel mean |Δ| a confirmed overlap must stay under
    private const int Candidates = 12;      // signature-best offsets compared on full pixels

    private readonly int _width, _height, _stride;
    private readonly int _margin; // columns ignored at each side: scrollbars and window shadows move
    private readonly List<byte[]> _slices = [];
    private byte[] _last;
    private int[] _lastSig;
    // Rows at the bottom that didn't scroll (a footer, or a blank stretch that only looked still): they
    // stay out of the slices and the last frame's copy closes the image, so nothing real is lost.
    private int _footerRows = -1;

    public int Height { get; private set; }
    public int Frames { get; private set; } = 1;

    public ScrollStitcher(byte[] firstFrame, int width, int height)
    {
        _width = width;
        _height = height;
        _stride = width * 4;
        _margin = Math.Clamp(width / 20, 4, 24);
        _last = firstFrame;
        _lastSig = Signatures(firstFrame);
        _slices.Add(firstFrame);
        Height = height;
    }

    public StitchStep Add(byte[] frame)
    {
        if (Height >= MaxHeight) return StitchStep.Full;
        var sig = Signatures(frame);
        if (MeanRowDiff(_lastSig, 0, sig, 0, _height) < StillFrame) return StitchStep.Unchanged;

        // Static bands: rows identical in both frames, counted inward from each edge.
        // Compared on full pixels: on signatures, lines of similar text one line apart look "unmoved",
        // the bands swallow the scrolling area and the offset search runs out of room.
        int header = 0;
        while (header < _height / 4 && RowPixelDiff(_last, frame, header) < StaticRow) header++;
        int footer = 0;
        while (footer < _height / 4 && RowPixelDiff(_last, frame, _height - 1 - footer) < StaticRow) footer++;
        int band = _height - header - footer;
        if (band < 40) return StitchStep.NoMatch;

        // Content moved up by d: previous rows [header+d, header+band) == current rows [header, header+band-d).
        // Signatures shortlist the offsets; full pixels pick among them. Repetitive content (lines of text
        // that differ only in a few glyphs) scores almost the same one line off on signatures alone.
        // Only local minima are shortlisted, so one wrong offset and its neighbours can't crowd out the right one.
        int minOverlap = Math.Max(20, band / 8);
        int maxD = band - minOverlap;
        if (maxD < 1) return StitchStep.NoMatch;
        var scores = new double[maxD + 1];
        for (int d = 1; d <= maxD; d++) scores[d] = MeanRowDiff(_lastSig, header + d, sig, header, band - d);
        var shortlist = Enumerable.Range(1, maxD)
            .Where(d => Enumerable.Range(Math.Max(1, d - 2), Math.Min(maxD, d + 2) - Math.Max(1, d - 2) + 1).All(n => scores[d] <= scores[n]))
            .OrderBy(d => scores[d])
            .Take(Candidates)
            .Select(d => (Score: scores[d], D: d));
        int best = -1;
        double bestPixels = MatchLimit;
        foreach (var (_, d) in shortlist)
        {
            double pixels = PixelDiff(_last, header + d, frame, header, band - d);
            if (pixels < bestPixels) { bestPixels = pixels; best = d; }
        }
        if (best < 0) return StitchStep.NoMatch;

        // Fixed on the first scroll: the footer leaves the first slice and is added once at the end.
        if (_footerRows < 0)
        {
            _footerRows = footer;
            if (footer > 0)
            {
                _slices[0] = Rows(_slices[0], 0, _height - footer);
                Height -= footer;
            }
        }

        int newRows = Math.Min(best, MaxHeight - Height);
        int from = _height - Math.Max(0, _footerRows) - best;
        if (from < 0) return StitchStep.NoMatch;
        _slices.Add(Rows(frame, from, newRows));
        Height += newRows;
        Frames++;
        _last = frame;
        _lastSig = sig;
        return StitchStep.Appended;
    }

    public BitmapSource ToBitmap()
    {
        int footerRows = Math.Max(0, _footerRows);
        int total = Height + footerRows;
        var pixels = new byte[total * _stride];
        int offset = 0;
        foreach (var slice in _slices)
        {
            Buffer.BlockCopy(slice, 0, pixels, offset, slice.Length);
            offset += slice.Length;
        }
        if (footerRows > 0) Buffer.BlockCopy(_last, (_height - footerRows) * _stride, pixels, offset, footerRows * _stride);
        var bmp = BitmapSource.Create(_width, total, 96, 96, PixelFormats.Bgr32, null, pixels, _stride);
        bmp.Freeze();
        return bmp;
    }

    private byte[] Rows(byte[] frame, int first, int count)
    {
        var rows = new byte[count * _stride];
        Buffer.BlockCopy(frame, first * _stride, rows, 0, rows.Length);
        return rows;
    }

    private int[] Signatures(byte[] frame)
    {
        var sig = new int[_height * SigColumns];
        int usable = _width - 2 * _margin;
        for (int y = 0; y < _height; y++)
        {
            int row = y * _stride;
            for (int c = 0; c < SigColumns; c++)
            {
                int x0 = _margin + usable * c / SigColumns, x1 = Math.Max(x0 + 1, _margin + usable * (c + 1) / SigColumns);
                int sum = 0;
                for (int x = x0; x < x1; x++)
                {
                    int i = row + x * 4;
                    sum += frame[i] + 2 * frame[i + 1] + frame[i + 2]; // cheap luminance, ×4
                }
                sig[y * SigColumns + c] = sum / (x1 - x0);
            }
        }
        return sig;
    }

    private static double RowDiff(int[] a, int rowA, int[] b, int rowB)
    {
        int ia = rowA * SigColumns, ib = rowB * SigColumns, sum = 0;
        for (int c = 0; c < SigColumns; c++) sum += Math.Abs(a[ia + c] - b[ib + c]);
        return sum / (4.0 * SigColumns);
    }

    private static double MeanRowDiff(int[] a, int firstA, int[] b, int firstB, int rows, double stopAbove = double.MaxValue)
    {
        double sum = 0, limit = stopAbove * rows;
        for (int r = 0; r < rows; r++)
        {
            sum += RowDiff(a, firstA + r, b, firstB + r);
            if (sum > limit) return double.MaxValue; // already worse than the best candidate
        }
        return sum / rows;
    }

    private double RowPixelDiff(byte[] a, byte[] b, int row)
    {
        int start = row * _stride;
        long sum = 0;
        for (int x = _margin; x < _width - _margin; x++)
        {
            int i = start + x * 4;
            sum += Math.Abs(a[i] - b[i]) + Math.Abs(a[i + 1] - b[i + 1]) + Math.Abs(a[i + 2] - b[i + 2]);
        }
        return (double)sum / (3 * (_width - 2 * _margin));
    }

    private double PixelDiff(byte[] a, int firstA, byte[] b, int firstB, int rows)
    {
        long sum = 0, count = 0;
        for (int r = 0; r < rows; r += 2)
        {
            int ia = (firstA + r) * _stride, ib = (firstB + r) * _stride;
            for (int x = _margin; x < _width - _margin; x += 2)
            {
                int i = x * 4;
                sum += Math.Abs(a[ia + i] - b[ib + i]) + Math.Abs(a[ia + i + 1] - b[ib + i + 1]) + Math.Abs(a[ia + i + 2] - b[ib + i + 2]);
                count += 3;
            }
        }
        return count == 0 ? double.MaxValue : (double)sum / count;
    }
}
