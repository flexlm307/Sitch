using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace Sitch.Capture;

/// <summary>What one frame did to the long image.</summary>
public enum StitchStep { Unchanged, Appended, NoMatch, Full }

/// <summary>
/// Joins frames of a region the user scrolls into one tall image (approach after evan's ScrollStitcher,
/// MIT). Frames are Bgr32 rows of the same width and height. Each new frame is matched against the
/// previous one: rows that stay put at the top (a sticky header) are found first and left out, the
/// scrolling middle is matched coarsely on per-row signatures, then confirmed on full pixels over its
/// best-matching rows. With the offset known, every row is classified against the previous frame: did it
/// stay put (a fixed overlay — a footer, or a floating translucent input box with content still scrolling
/// beneath it) or move with the content, and if it moved, did it arrive intact (clean) or changed (under a
/// fade mask or a blur)? Only each frame's clean band is painted onto the canvas, so content that enters
/// dimmed at the bottom is painted again once it has scrolled into the clear; the last frame's lower part
/// closes the image, so an overlay appears once, at the end. When only part of the region scrolls — a
/// window with a fixed side panel — the first match finds the columns that moved, and from then on only that
/// span is compared and kept: the long image is the part that scrolls, and a toolbar across its top is an
/// ordinary fixed header. Only downward scrolling extends the image.
/// Same algorithm as mac/Sources/SitchCore/ScrollStitcher.swift (unit-tested there).
/// </summary>
public sealed class ScrollStitcher
{
    public const int MaxHeight = 30000;

    private const int SigColumns = 64;      // per-row signature: average luminance of 64 column bands
    private const double StaticRow = 0.5;   // mean |Δ| per pixel channel under which a row "didn't move"
    private const double StillFrame = 2.0;  // whole-frame mean |Δ| under which nothing scrolled
    private const double MatchLimit = 10.0; // mean |Δ| over the best-matching rows a confirmed overlap must stay under
    private const int Candidates = 12;      // signature-best offsets compared on full pixels
    private const double ChangedRow = 8.0;  // a row changed in place by more than this has content going by
    private const double IntactRow = 1.0;   // a moved row differing more than this (or 3× the median) didn't arrive intact

    private readonly int _width, _height, _stride;
    // Columns compared: inside the kept span, minus a margin at each side (scrollbars and window shadows move).
    private int _colLo, _colHi;
    // Columns kept in the long image: the whole width until a fixed side panel is found.
    private int _cropLo, _cropHi;
    private bool _columnsDecided;
    private byte[] _canvas;
    private int _frameTop;        // canvas row of the current frame's row 0
    private byte[] _last;
    private int[] _lastSig;
    private int _lastCleanBottom; // the previous frame's clean band ends here: rows below stay out of the match

    /// <summary>The long image's height so far (the last frame's bottom included).</summary>
    public int Height => _frameTop + _height;
    public int Frames { get; private set; } = 1;

    public ScrollStitcher(byte[] firstFrame, int width, int height)
    {
        _width = width;
        _height = height;
        _stride = width * 4;
        _colLo = Margin(width);
        _colHi = width - _colLo;
        _cropHi = width;
        _canvas = (byte[])firstFrame.Clone();
        _last = firstFrame;
        _lastSig = Signatures(firstFrame);
        _lastCleanBottom = height;
    }

    public StitchStep Add(byte[] frame)
    {
        if (Height >= MaxHeight) return StitchStep.Full;
        var sig = Signatures(frame);
        if (MeanRowDiff(_lastSig, 0, sig, 0, _height) < StillFrame) return StitchStep.Unchanged;

        // Static bands: rows identical in both frames, counted inward from each edge. Compared on full
        // pixels: on signatures, lines of similar text one line apart look "unmoved". The bottom also stops
        // at the last frame's clean band, which keeps a known overlay out of the match.
        int header = StaticHeader(frame);
        int footer = _height - _lastCleanBottom;
        while (footer < _height / 4 && RowPixelDiff(_last, _height - 1 - footer, frame, _height - 1 - footer) < StaticRow) footer++;
        int band = _height - header - footer;
        if (band < 40) return StitchStep.NoMatch;

        // Content moved up by d: previous rows [header+d, header+band) == current rows [header, header+band-d).
        // Signatures shortlist the offsets (local minima only, so one wrong offset and its neighbours can't
        // crowd out the right one); full pixels pick among them.
        int minOverlap = Math.Max(20, band / 8);
        int maxD = band - minOverlap;
        if (maxD < 1) return StitchStep.NoMatch;
        var scores = new double[maxD + 1];
        for (int d = 1; d <= maxD; d++) scores[d] = MeanRowDiff(_lastSig, header + d, sig, header, band - d);
        var shortlist = Enumerable.Range(1, maxD)
            .Where(d => Enumerable.Range(Math.Max(1, d - 2), Math.Min(maxD, d + 2) - Math.Max(1, d - 2) + 1).All(n => scores[d] <= scores[n]))
            .OrderBy(d => scores[d])
            .Take(Candidates);
        int best = -1;
        double bestPixels = MatchLimit;
        foreach (var d in shortlist)
        {
            double pixels = PixelDiff(_last, header + d, frame, header, band - d);
            if (pixels < bestPixels) { bestPixels = pixels; best = d; }
        }
        if (best < 0) return StitchStep.NoMatch;

        // Columns are judged once, on a step small enough to leave rows to compare in the frame's middle half.
        if (!_columnsDecided && best <= _height / 2 - 20)
        {
            _columnsDecided = true;
            if (ScrollingColumns(frame, best) is { } span)
            {
                (_cropLo, _cropHi) = span;
                int margin = Margin(_cropHi - _cropLo);
                _colLo = _cropLo + margin;
                _colHi = _cropHi - margin;
                _lastSig = Signatures(_last);
                sig = Signatures(frame);
                header = StaticHeader(frame);
            }
        }
        var (cleanTop, cleanBottom) = CleanBand(frame, best, header);
        // The clean bands of consecutive frames must overlap, or a stretch of content was never seen intact.
        if (best >= cleanBottom - cleanTop) return StitchStep.NoMatch;

        int newTop = Math.Min(_frameTop + best, MaxHeight - _height);
        int needed = (newTop + _height) * _stride;
        if (_canvas.Length < needed) Array.Resize(ref _canvas, needed);
        Buffer.BlockCopy(frame, cleanTop * _stride, _canvas, (newTop + cleanTop) * _stride, (cleanBottom - cleanTop) * _stride);
        _frameTop = newTop;
        Frames++;
        _last = frame;
        _lastSig = sig;
        _lastCleanBottom = cleanBottom;
        return StitchStep.Appended;
    }

    public BitmapSource ToBitmap()
    {
        int total = Height;
        var pixels = new byte[total * _stride];
        Buffer.BlockCopy(_canvas, 0, pixels, 0, Math.Min(_canvas.Length, pixels.Length));
        // The last frame's lower part closes the image: an overlay at the bottom appears once, here.
        int from = _lastCleanBottom * _stride;
        Buffer.BlockCopy(_last, from, pixels, _frameTop * _stride + from, _last.Length - from);
        int outWidth = _cropHi - _cropLo, outStride = outWidth * 4;
        if (outWidth != _width)
        {
            var cropped = new byte[total * outStride];
            for (int y = 0; y < total; y++) Buffer.BlockCopy(pixels, y * _stride + _cropLo * 4, cropped, y * outStride, outStride);
            pixels = cropped;
        }
        var bmp = BitmapSource.Create(outWidth, total, 96, 96, PixelFormats.Bgr32, null, pixels, outStride);
        bmp.Freeze();
        return bmp;
    }

    /// <summary>
    /// The rows of the frame that show content as it really is. Each row is weighed against the previous
    /// frame, the offset known: it arrived intact (matches where that content was, though it changed in place
    /// — clean), it didn't (it stayed put while the content moved, or arrived changed: a header or footer, a
    /// translucent bar showing blurred content through, an overlay, a fade), or it can't tell (a blank row
    /// matches either way). The band runs from below the last bad row above the first stretch of clean rows
    /// to above the first bad row below the last such stretch, so blank rows inside a translucent bar can't
    /// end it early and the bar's rows never reach the canvas, where they would cover content already painted.
    /// </summary>
    private (int Top, int Bottom) CleanBand(byte[] frame, int d, int header)
    {
        // moved[y]: frame row y against where that content was in the last frame (row y+d).
        var moved = new double[_height];
        Array.Fill(moved, double.MaxValue);
        for (int y = 0; y < _height - d; y++) moved[y] = RowPixelDiff(_last, y + d, frame, y);
        var middle = moved[header..(_height - d)].OrderBy(v => v).ToArray();
        double median = middle.Length == 0 ? 0 : middle[middle.Length / 2];
        double ok = Math.Max(IntactRow, median * 3);

        // 1 clean, -1 bad, 0 can't tell. Clean takes a real change in place (text going by), not the drift
        // of blurred content seen through a translucent bar, which also matches itself shifted.
        int Kind(int y)
        {
            if (moved[y] > ok) return -1;
            return RowPixelDiff(_last, y, frame, y) > Math.Max(ChangedRow, ok * 4) ? 1 : 0;
        }
        // Content shifted within a translucent bar matches itself (the bar tints every row alike), so a few
        // clean rows prove nothing there: the band needs a stretch of clean rows — counted across blank ones,
        // reset by a bad one — before it trusts that it has left a bar.
        int run = Math.Max(3, _height / 20);

        int top = header, cleanRun = 0;
        for (int y = header; y < _height / 2 && cleanRun < run; y++)
        {
            int k = Kind(y);
            if (k < 0) { top = y + 1; cleanRun = 0; }
            else if (k > 0) cleanRun++;
        }
        int bottom = _height;
        cleanRun = 0;
        for (int y = _height - 1; y >= Math.Max(top + 1, _height / 2) && cleanRun < run; y--)
        {
            int k = Kind(y);
            if (k < 0) { bottom = y; cleanRun = 0; }
            else if (k > 0) cleanRun++;
        }
        return (top, Math.Max(bottom, top + 1));
    }

    private static int Margin(int width) => Math.Clamp(width / 20, 4, 24);

    /// <summary>Rows identical in both frames, counted down from the top: a toolbar or a sticky header.</summary>
    private int StaticHeader(byte[] frame)
    {
        int header = 0;
        while (header < _height / 4 && RowPixelDiff(_last, header, frame, header) < StaticRow) header++;
        return header;
    }

    /// <summary>
    /// With the offset known, the columns that moved with the content, or null when the whole width did.
    /// Judged on the middle half of the frame (headers, footers and floating boxes sit at the edges), per
    /// column, by evidence: a pixel that changed in place but matches the shifted content says "scrolls", one
    /// that stayed put while the content moved says "stays". The columns that scroll form the core; it widens
    /// over columns without evidence (page margins) until it meets a fixed column or a vertical edge running
    /// down nearly the whole frame — the border or background change at a side panel — so a blank strip of a
    /// fixed sidebar isn't kept.
    /// </summary>
    private (int Lo, int Hi)? ScrollingColumns(byte[] frame, int d)
    {
        // Both ends of each comparison stay in the middle half: an overlay in the last frame would say "stays".
        var rows = new List<int>();
        for (int y = _height / 4; y < _height * 3 / 4 - d; y += 2) rows.Add(y);
        if (rows.Count < 10) return null;
        int minEvidence = Math.Max(3, rows.Count / 20);
        var scrolls = new int[_width];
        var fixedCol = new bool[_width];
        for (int x = 0; x < _width; x++)
        {
            int stays = 0, moves = 0;
            foreach (int y in rows)
            {
                int i = y * _stride + x * 4, j = (y + d) * _stride + x * 4;
                int s = 0, m = 0;
                for (int c = 0; c < 3; c++)
                {
                    s += Math.Abs(_last[i + c] - frame[i + c]);
                    m += Math.Abs(_last[j + c] - frame[i + c]);
                }
                if (s < 6 && m > 30) stays++;
                else if (m < 6 && s > 30) moves++;
            }
            scrolls[x] = moves;
            fixedCol[x] = stays >= Math.Max(minEvidence, rows.Count / 8) && moves * 4 <= stays;
        }
        // A vertical edge between x-1 and x: the two columns differ on nearly every row of the frame.
        bool Edge(int x)
        {
            int differ = 0, total = 0;
            for (int y = 0; y < _height; y += 2)
            {
                int i = y * _stride + x * 4, diff = 0;
                for (int c = 0; c < 3; c++) diff += Math.Abs(frame[i + c] - frame[i - 4 + c]);
                if (diff > 9) differ++;
                total++;
            }
            return differ * 10 >= total * 9;
        }
        var moving = Enumerable.Range(0, _width).Where(x => scrolls[x] >= minEvidence && !fixedCol[x]).ToList();
        if (moving.Count == 0) return null;
        int lo = moving[0], hi = moving[^1] + 1;
        // A fixed column inside the moving range: keep the side with more scrolling columns.
        int cut = Enumerable.Range(lo, hi - lo).FirstOrDefault(x => fixedCol[x], -1);
        if (cut >= 0)
        {
            int left = moving.Count(x => x < cut), right = moving.Count - left;
            if (left >= right) hi = cut;
            else
            {
                int next = Enumerable.Range(cut, hi - cut).FirstOrDefault(x => !fixedCol[x] && scrolls[x] >= minEvidence, -1);
                lo = next >= 0 ? next : cut + 1;
            }
            int lastBelow = moving.LastOrDefault(x => x < hi, hi - 1);
            hi = Math.Min(hi, lastBelow + 1);
        }
        while (lo > 0 && !fixedCol[lo - 1] && !Edge(lo)) lo--;
        while (hi < _width && !fixedCol[hi] && !Edge(hi)) hi++;
        // A sliver of fixed columns (a window edge) isn't a side panel; and a span too narrow to read is a fluke.
        if (_width - (hi - lo) <= _width / 20 || hi - lo < 60) return null;
        return (lo, hi);
    }

    private int[] Signatures(byte[] frame)
    {
        var sig = new int[_height * SigColumns];
        int usable = _colHi - _colLo;
        for (int y = 0; y < _height; y++)
        {
            int row = y * _stride;
            for (int c = 0; c < SigColumns; c++)
            {
                int x0 = _colLo + usable * c / SigColumns, x1 = Math.Max(x0 + 1, _colLo + usable * (c + 1) / SigColumns);
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

    private static double MeanRowDiff(int[] a, int firstA, int[] b, int firstB, int rows)
    {
        long sum = 0;
        for (int r = 0; r < rows; r++)
        {
            int ia = (firstA + r) * SigColumns, ib = (firstB + r) * SigColumns;
            for (int c = 0; c < SigColumns; c++) sum += Math.Abs(a[ia + c] - b[ib + c]);
        }
        return sum / (4.0 * SigColumns) / rows;
    }

    /// <summary>Mean |Δ| per channel between row <paramref name="rowA"/> of a and row <paramref name="rowB"/> of b.</summary>
    private double RowPixelDiff(byte[] a, int rowA, byte[] b, int rowB)
    {
        int sa = rowA * _stride, sb = rowB * _stride;
        long sum = 0;
        for (int x = _colLo; x < _colHi; x++)
        {
            int i = x * 4;
            sum += Math.Abs(a[sa + i] - b[sb + i]) + Math.Abs(a[sa + i + 1] - b[sb + i + 1]) + Math.Abs(a[sa + i + 2] - b[sb + i + 2]);
        }
        return (double)sum / (3 * (_colHi - _colLo));
    }

    /// <summary>
    /// Mean |Δ| per channel over the best-matching 60% of the rows, each row itself scored on its
    /// best-matching 60% of 16 column blocks (every other row and column sampled): an overlay, a fade or a
    /// fixed side panel covering up to 40% of the band either way can't veto the right offset, while a wrong
    /// offset still differs almost everywhere.
    /// </summary>
    private double PixelDiff(byte[] a, int firstA, byte[] b, int firstB, int rows)
    {
        const int blocks = 16;
        int span = _colHi - _colLo;
        if (span < blocks) return double.MaxValue;
        var perRow = new List<double>(rows / 2 + 1);
        var blockDiff = new double[blocks];
        for (int r = 0; r < rows; r += 2)
        {
            int ia = (firstA + r) * _stride, ib = (firstB + r) * _stride;
            for (int k = 0; k < blocks; k++)
            {
                int x0 = _colLo + span * k / blocks, x1 = _colLo + span * (k + 1) / blocks;
                long sum = 0, count = 0;
                for (int x = x0; x < x1; x += 2)
                {
                    int i = x * 4;
                    sum += Math.Abs(a[ia + i] - b[ib + i]) + Math.Abs(a[ia + i + 1] - b[ib + i + 1]) + Math.Abs(a[ia + i + 2] - b[ib + i + 2]);
                    count += 3;
                }
                blockDiff[k] = count == 0 ? 0 : (double)sum / count;
            }
            Array.Sort(blockDiff);
            const int keptBlocks = blocks * 6 / 10;
            double rowSum = 0;
            for (int k = 0; k < keptBlocks; k++) rowSum += blockDiff[k];
            perRow.Add(rowSum / keptBlocks);
        }
        if (perRow.Count == 0) return double.MaxValue;
        perRow.Sort();
        int keep = Math.Max(1, perRow.Count * 6 / 10);
        return perRow.Take(keep).Average();
    }
}
