using System.Windows;
using System.Windows.Automation;
using System.Windows.Threading;

namespace Sitch.Capture;

/// <summary>One element under the pointer: its visible rect (physical px, clipped to its ancestors so
/// scrolled-away content doesn't count) and its control type name in Sitch's language ("Button", "按钮").</summary>
public sealed record SnapTarget(Int32Rect Bounds, string Kind);

/// <summary>
/// Region capture's hover snapping: the chain of UI elements under the pointer, outermost (the top-level
/// window) first. Walks UI Automation's control view down from the hovered window — never ElementFromPoint,
/// which would hit our own overlay — on a worker thread, because cross-process UIA calls can take tens of
/// milliseconds. Only the newest request matters: queued points collapse and stale answers are dropped.
/// </summary>
public sealed class ElementSnapper(Action<WindowEntry, IReadOnlyList<SnapTarget>> onResult)
{
    private const int MaxDepth = 40;
    private const int MaxSiblings = 500;
    private const int BudgetMs = 300;

    private readonly Dispatcher _dispatcher = Dispatcher.CurrentDispatcher;
    private int _generation;
    private bool _busy;
    private (WindowEntry Window, Point Point)? _pending;

    public void Request(WindowEntry window, Point physical)
    {
        _pending = (window, physical);
        if (!_busy) Next();
    }

    public void Cancel()
    {
        _generation++;
        _pending = null;
    }

    private void Next()
    {
        if (_pending is not { } job) { _busy = false; return; }
        _pending = null;
        _busy = true;
        int generation = _generation;
        Task.Run(() =>
        {
            IReadOnlyList<SnapTarget> chain;
            try { chain = Walk(job.Window, job.Point); }
            catch { chain = []; } // the app went away or refuses UIA: plain window snapping
            _dispatcher.BeginInvoke(() =>
            {
                // A newer point is queued: its answer replaces this one, so skip the flicker.
                if (generation == _generation && _pending is null) onResult(job.Window, chain);
                Next();
            });
        });
    }

    private static List<SnapTarget> Walk(WindowEntry window, Point p)
    {
        var root = AutomationElement.FromHandle(window.Hwnd);
        var chain = new List<SnapTarget> { new(window.Bounds, Kind(root)) };
        var walker = TreeWalker.ControlViewWalker;
        var clip = new Rect(window.Bounds.X, window.Bounds.Y, window.Bounds.Width, window.Bounds.Height);
        long deadline = Environment.TickCount64 + BudgetMs;

        var current = root;
        for (int depth = 0; depth < MaxDepth && Environment.TickCount64 < deadline; depth++)
        {
            // UIA child order is not z-order; the smallest child holding the point is the most specific.
            AutomationElement? best = null;
            Rect bestRect = Rect.Empty;
            int seen = 0;
            for (var child = walker.GetFirstChild(current);
                 child is not null && seen < MaxSiblings;
                 child = walker.GetNextSibling(child), seen++)
            {
                Rect r;
                try { r = child.Current.BoundingRectangle; }
                catch (ElementNotAvailableException) { continue; }
                if (r.IsEmpty || r.Width < 2 || r.Height < 2 || !r.Contains(p)) continue;
                double area = r.Width * r.Height, bestArea = bestRect.Width * bestRect.Height;
                // Ties go to the element that leads deeper: Chromium puts a childless, window-sized
                // "Intermediate D3D Window" pane ahead of its real RootView.
                if (best is null || area < bestArea ||
                    (area == bestArea && walker.GetFirstChild(best) is null && walker.GetFirstChild(child) is not null))
                { best = child; bestRect = r; }
            }
            if (best is null) break;

            bestRect.Intersect(clip);
            if (bestRect.IsEmpty || !bestRect.Contains(p)) break;
            clip = bestRect;
            var bounds = new Int32Rect((int)Math.Round(bestRect.X), (int)Math.Round(bestRect.Y),
                (int)Math.Round(bestRect.Width), (int)Math.Round(bestRect.Height));
            // Wrappers the same size as their parent add a wheel step that shows nothing new.
            // The window keeps its own name; deeper levels take the innermost one.
            if (bounds == chain[^1].Bounds) { if (chain.Count > 1) chain[^1] = chain[^1] with { Kind = Kind(best) }; }
            else chain.Add(new SnapTarget(bounds, Kind(best)));
            current = best;
        }
        return chain;
    }

    // LocalizedControlType mixes languages (Win32 proxies answer in English, UWP apps in the OS language),
    // so name the control type ourselves.
    private static string Kind(AutomationElement e)
    {
        try { return Shell.Loc.T(e.Current.ControlType.ProgrammaticName.Replace("ControlType.", "")); }
        catch { return ""; }
    }
}
