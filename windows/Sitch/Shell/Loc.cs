using System.Globalization;
using System.Windows.Markup;

namespace Sitch.Shell;

/// <summary>
/// Sitch's UI words in English (the keys) and Chinese. The language is resolved once, on first use after
/// settings load, so a change in Settings applies after a restart — windows and menus are built once.
/// </summary>
public static class Loc
{
    private static bool? _zh;

    /// <summary>"System" follows the Windows display language.</summary>
    public static bool IsChinese => _zh ??= App.Settings.Language switch
    {
        "zh" => true,
        "en" => false,
        _ => CultureInfo.CurrentUICulture.TwoLetterISOLanguageName == "zh",
    };

    public static string T(string en) => IsChinese && Zh.TryGetValue(en, out var zh) ? zh : en;

    public static string F(string en, params object?[] args) => string.Format(T(en), args);

    private static readonly Dictionary<string, string> Zh = new()
    {
        // Tray
        ["Sitch — Capture. Annotate. Share."] = "Sitch — 截图、标注、分享",
        ["Capture Region"] = "截取区域",
        ["Capture Window"] = "截取窗口",
        ["Capture Full Screen"] = "截取全屏",
        ["Display {0} ({1}×{2})"] = "显示器 {0}（{1}×{2}）",
        [" — primary"] = " — 主显示器",
        ["Recapture Last Region"] = "重截上次区域",
        ["Quick Capture → Clipboard"] = "快速截图 → 剪贴板",
        ["Quick Capture → File"] = "快速截图 → 文件",
        ["Open Image…"] = "打开图片…",
        ["New Note"] = "新便签",
        ["Line Settings…"] = "晾衣绳设置…",
        ["Line settings…"] = "晾衣绳设置…",
        ["Hide Screenshot Line"] = "隐藏截图晾衣绳",
        ["Show Screenshot Line"] = "显示截图晾衣绳",
        ["Settings…"] = "设置…",
        ["About Sitch"] = "关于 Sitch",
        ["Quit Sitch"] = "退出 Sitch",
        ["Images"] = "图片",
        ["All files"] = "所有文件",
        ["Skitch-style screenshot annotation for Windows.\nCapture. Annotate. Share."] = "Skitch 风格的 Windows 截图标注工具。\n截图、标注、分享。",

        // Welcome
        ["Welcome to Sitch"] = "欢迎使用 Sitch",
        ["Sitch is ready"] = "Sitch 已就绪",
        ["Capture. Annotate. Share."] = "截图、标注、分享。",
        ["Press  {0}  to capture — drag a region or click a window."] = "按  {0}  截图 — 拖出一个区域，或点击一个窗口或控件。",
        ["Sitch lives in your system tray: click the pink-arrow icon to capture, right-click it for window capture, full screen, timers and Settings."] =
            "Sitch 常驻在系统托盘：点击粉色箭头图标截图，右键可截取窗口、全屏，以及使用定时和设置。",
        ["Tip: if you don't see the icon, it's in the  ^  overflow area next to the clock — drag it onto the taskbar to pin it."] =
            "提示：如果看不到图标，它在时钟旁的  ^  溢出区里 — 把它拖到任务栏上即可固定。",
        ["Every capture is copied to your clipboard automatically, ready to paste."] = "每次截图都会自动复制到剪贴板，可以直接粘贴。",
        ["Settings"] = "设置",
        ["Capture now  ({0})"] = "立即截图  （{0}）",

        // App
        ["Capture"] = "截图",
        ["Recapture last region"] = "重截上次区域",
        ["Capture to clipboard"] = "截图到剪贴板",
        ["{0} hotkey {1} is already used by {2}."] = "“{0}”的快捷键 {1} 已被“{2}”占用。",
        ["{0} hotkey {1} is in use by another app."] = "“{0}”的快捷键 {1} 已被其他程序占用。",
        ["Copied to clipboard."] = "已复制到剪贴板。",
        ["Clipboard busy — saved {0} instead."] = "剪贴板被占用 — 已改为保存 {0}。",
        ["Saved {0}"] = "已保存 {0}",
        ["Clipboard is busy — opening the editor instead."] = "剪贴板被占用 — 改为打开编辑器。",
        ["Untitled"] = "未命名",
        ["Couldn't open {0}"] = "无法打开 {0}",
        ["Sitch is already running in the system tray.\nPress {0} to capture."] = "Sitch 已在系统托盘中运行。\n按 {0} 截图。",
        ["Compressed {0}: {1} → {2}"] = "已压缩 {0}：{1} → {2}",
        ["MediaMini could not compress {0}: {1}"] = "MediaMini 压缩 {0} 失败：{1}",
        ["cli.py not found in {0}"] = "在 {0} 中找不到 cli.py",

        // Share
        ["Share isn't available here — copied to clipboard instead."] = "这里无法使用分享 — 已改为复制到剪贴板。",
        ["Share isn't available right now."] = "暂时无法分享。",

        // Tools
        ["Select"] = "选择",
        ["Arrow"] = "箭头",
        ["Text"] = "文字",
        ["Rectangle"] = "矩形",
        ["Ellipse"] = "椭圆",
        ["Line"] = "直线",
        ["Highlight"] = "高亮",
        ["Obscure"] = "打码",
        ["Stamp"] = "图章",
        ["Pen"] = "画笔",
        ["Spotlight"] = "聚光灯",
        ["Sticker"] = "贴纸",
        ["Image"] = "图片",
        ["Crop"] = "裁剪",

        // UI Automation control types (capture snapping readout)
        ["Window"] = "窗口", ["Pane"] = "窗格", ["Button"] = "按钮", ["Document"] = "文档", ["Edit"] = "输入框",
        ["List"] = "列表", ["ListItem"] = "列表项", ["Tree"] = "树", ["TreeItem"] = "树节点", ["Menu"] = "菜单",
        ["MenuItem"] = "菜单项", ["MenuBar"] = "菜单栏", ["ToolBar"] = "工具栏", ["StatusBar"] = "状态栏",
        ["Tab"] = "选项卡", ["TabItem"] = "选项卡项", ["Group"] = "分组", ["Hyperlink"] = "链接",
        ["CheckBox"] = "复选框", ["RadioButton"] = "单选按钮", ["ComboBox"] = "下拉框", ["Table"] = "表格",
        ["DataGrid"] = "表格", ["DataItem"] = "数据项", ["Header"] = "表头", ["HeaderItem"] = "表头项",
        ["Custom"] = "自定义", ["TitleBar"] = "标题栏", ["ScrollBar"] = "滚动条", ["Slider"] = "滑块",
        ["ProgressBar"] = "进度条", ["SplitButton"] = "拆分按钮", ["Calendar"] = "日历", ["Spinner"] = "微调框",
        ["Thumb"] = "拖块", ["ToolTip"] = "提示", ["Separator"] = "分隔线", ["AppBar"] = "应用栏",
        ["SemanticZoom"] = "缩放视图",

        // Editor
        ["New Capture (region)"] = "新截图（区域）",
        ["New Capture"] = "新截图",
        ["Tapered (Skitch-style)"] = "渐细（Skitch 风格）",
        ["Filled"] = "实心",
        ["Open"] = "空心",
        ["Concave"] = "内凹",
        ["Double-headed"] = "双向",
        ["Bold"] = "粗体",
        ["Italic"] = "斜体",
        ["Outline"] = "描边",
        ["Pixelate"] = "像素化",
        ["Blur"] = "模糊",
        ["Block"] = "色块",
        ["Stripes"] = "条纹",
        ["Check"] = "对勾",
        ["Cross"] = "叉号",
        ["Star"] = "星形",
        ["Dot"] = "圆点",
        ["Auto-incrementing numbers"] = "自动递增编号",
        ["Pick emoji"] = "选择表情",
        ["click the image to place"] = "点击图片放置",
        ["drag to spotlight — everything else dims"] = "拖动框出聚光区域 — 其余部分变暗",
        ["Proportional lock"] = "锁定比例",
        ["Cancel"] = "取消",
        ["Apply"] = "应用",
        ["Current color — click to change"] = "当前颜色 — 点击更改",
        ["Undo (Ctrl+Z)"] = "撤销（Ctrl+Z）",
        ["Redo (Ctrl+Y)"] = "重做（Ctrl+Y）",
        ["Delete selection / clear all"] = "删除所选 / 全部清除",
        ["Zoom out"] = "缩小",
        ["Zoom"] = "缩放",
        ["Zoom in"] = "放大",
        ["Drag me into any app"] = "把我拖进任意应用",
        ["Copy image (Ctrl+Shift+C)"] = "复制图片（Ctrl+Shift+C）",
        ["Save (Ctrl+S)"] = "保存（Ctrl+S）",
        ["Share"] = "分享",
        ["Close tab"] = "关闭标签页",
        ["Custom color…"] = "自定义颜色…",
        ["Free"] = "自由",
        ["Original"] = "原始比例",
        ["Rotate Left"] = "向左旋转",
        ["Rotate Right"] = "向右旋转",
        ["Flip Horizontal"] = "水平翻转",
        ["Flip Vertical"] = "垂直翻转",
        ["Bring Forward"] = "上移一层",
        ["Send Backward"] = "下移一层",
        ["Delete"] = "删除",
        ["Couldn't insert image."] = "无法插入图片。",
        ["Fit"] = "适合窗口",
        ["Clipboard is busy — try again."] = "剪贴板被占用 — 请重试。",
        ["Save to {0}"] = "保存到 {0}",
        ["Save As…"] = "另存为…",
        ["Save failed."] = "保存失败。",
        ["Remove all annotations?"] = "删除所有标注？",
        ["“{0}” has unsaved changes. Save before closing?"] = "“{0}”有未保存的更改。关闭前要保存吗？",

        // Settings
        ["Sitch Settings"] = "Sitch 设置",
        ["General"] = "通用",
        ["Editor"] = "编辑器",
        ["APPEARANCE"] = "外观",
        ["System"] = "跟随系统",
        ["Light"] = "浅色",
        ["Dark"] = "深色",
        ["LANGUAGE"] = "语言",
        ["Restart Sitch to apply a new language."] = "重启 Sitch 后新语言生效。",
        ["BEHAVIOR"] = "行为",
        ["Show editor windows in the taskbar"] = "在任务栏显示编辑器窗口",
        ["Open at login"] = "登录时启动",
        ["Sitch lives in your system tray — click the tray icon to capture, right-click for everything else."] = "Sitch 常驻在系统托盘 — 点击托盘图标截图，右键查看其他功能。",
        ["SHORTCUTS"] = "快捷键",
        ["Click, then press the new key combination"] = "点击后按下新的组合键",
        ["Click a field and press any combination (e.g. Ctrl+Alt+4 or Ctrl+Shift+PrintScreen). Esc reverts."] = "点击输入框后按下任意组合键（如 Ctrl+Alt+4 或 Ctrl+Shift+PrintScreen）。按 Esc 恢复原值。",
        ["SAVING"] = "保存",
        ["Browse…"] = "浏览…",
        ["Default format"] = "默认格式",
        ["Compress saved images with MediaMini"] = "用 MediaMini 压缩保存的图片",
        ["MediaMini folder"] = "MediaMini 文件夹",
        ["After each save, Sitch runs cli.py from MediaMini on the PNG or JPG in the background and replaces it only when it gets smaller. Needs Python on the PATH."] =
            "每次保存后，Sitch 会在后台用 MediaMini 的 cli.py 处理 PNG 或 JPG，只在文件变小时替换。需要 PATH 中有 Python。",
        ["AFTER CAPTURING"] = "截图之后",
        ["Show the editor"] = "打开编辑器",
        ["Copy to clipboard"] = "复制到剪贴板",
        ["Save to file"] = "保存为文件",
        ["Hang on the screenshot line"] = "挂到截图晾衣绳上",
        ["SCREENSHOT LINE"] = "截图晾衣绳",
        ["Keep captures on a line along the top of the screen"] = "把截图挂在屏幕顶端的一根绳上",
        ["TIMER & WATCHER"] = "定时与监视",
        ["Capture timer"] = "截图定时",
        ["Open the editor after a system screenshot (Win+PrtScn)"] = "系统截图（Win+PrtScn）后打开编辑器",
        ["SNAPPING"] = "吸附",
        ["Snap to the element under the pointer"] = "吸附鼠标下的元素",
        ["Hover highlights the control, page or window under the pointer; the mouse wheel steps out to its parent and back. Click to capture it."] =
            "悬停时高亮鼠标下的控件、页面或窗口；滚动鼠标滚轮可切换到上一级元素或返回。单击即可截取。",
        ["Show a magnifier and the colour under the pointer"] = "显示放大镜和鼠标下的颜色",
        ["While capturing, press C to copy the colour as HEX, Shift+C as RGB."] = "截图时按 C 复制 HEX 颜色值，按 Shift+C 复制 RGB 值。",
        ["C: copy HEX · Shift+C: RGB"] = "C 复制 HEX · Shift+C 复制 RGB",
        ["Copied {0}"] = "已复制 {0}",
        ["Extract text (Ctrl+Shift+O)"] = "提取文字（Ctrl+Shift+O）",
        ["Scrolling capture"] = "长截图",
        ["Scrolling Capture"] = "长截图（滚动截图）",
        ["Choose a larger area to scroll."] = "请选择更大的区域进行滚动截图。",
        ["Scroll the area slowly…"] = "请慢慢滚动该区域…",
        ["Lost track — scroll back a little, then slower"] = "没对上 — 请往回滚一点，再慢一些",
        ["Maximum height reached"] = "已达到最大高度",
        ["{0} px · {1} frames"] = "{0} px · {1} 帧",
        ["Done"] = "完成",
        ["Nothing scrolled — keeping a normal capture."] = "没有检测到滚动 — 保留为普通截图。",
        ["Hover highlights the control, page or window under the pointer; the mouse wheel steps out to its parent and back. Click to capture it, press F3 to pin it on screen, or S to start a scrolling capture of it."] =
            "悬停时高亮鼠标下的控件、页面或窗口；滚动鼠标滚轮可切换到上一级元素或返回。单击截取，按 F3 贴到屏幕上，按 S 对它进行长截图。",
        ["Pin clipboard image"] = "贴图剪贴板图片",
        ["Pin Clipboard Image"] = "贴图剪贴板图片",
        ["Close All Pins"] = "关闭全部贴图",
        ["Pin to screen (F3)"] = "贴到屏幕（F3）",
        ["Pinned capture"] = "贴图",
        ["No image on the clipboard to pin."] = "剪贴板里没有可以贴图的图片。",
        ["Open in editor"] = "在编辑器中打开",
        ["Extract text"] = "提取文字",
        ["Actual size"] = "原始大小",
        ["Opacity"] = "透明度",
        ["Close all pins"] = "关闭全部贴图",
        ["Hover highlights the control, page or window under the pointer; the mouse wheel steps out to its parent and back. Click to capture it, or press F3 to pin it on screen."] =
            "悬停时高亮鼠标下的控件、页面或窗口；滚动鼠标滚轮可切换到上一级元素或返回。单击截取，按 F3 贴到屏幕上。",
        ["TEXT RECOGNITION (OCR)"] = "文字识别（OCR）",
        ["Windows built-in"] = "Windows 自带",
        ["RapidOCR (better for Chinese and mixed text)"] = "RapidOCR（中文和中英混排更准）",
        ["RapidOCR needs Python and: pip install rapidocr. The first read after starting Sitch takes a few seconds while it loads; if it fails, Windows OCR is used."] =
            "RapidOCR 需要 Python，并运行 pip install rapidocr。Sitch 启动后第一次识别要加载几秒；失败时自动改用 Windows OCR。",
        ["RapidOCR failed, using Windows OCR: {0}"] = "RapidOCR 识别失败，已改用 Windows OCR：{0}",
        ["Extracted text"] = "提取的文字",
        ["Close"] = "关闭",
        ["Copy"] = "复制",
        ["Text copied"] = "文字已复制",
        ["Reading text…"] = "正在识别文字…",
        ["Could not read text."] = "无法识别文字。",
        ["No text found."] = "没有识别到文字。",
        ["Windows has no OCR language installed. Add one in Settings > Time & language > Language."] =
            "Windows 没有安装 OCR 语言。请在 设置 > 时间和语言 > 语言 中添加。",
        ["TOOLS"] = "工具",
        ["Remember the last used tool"] = "记住上次使用的工具",
        ["Arrow width (px)"] = "箭头粗细（px）",
        ["Text size (pt)"] = "文字大小（pt）",
        ["SPOTLIGHT"] = "聚光灯",
        ["How much everything outside a spotlight is dimmed."] = "聚光区域以外变暗的程度。",
        ["Couldn't update startup entry."] = "无法更新开机启动项。",
        ["Off"] = "关闭",
        ["3 s"] = "3 秒",
        ["5 s"] = "5 秒",
        ["10 s"] = "10 秒",
        ["Show or hide it with {0}"] = "用 {0} 显示或隐藏",
        ["Quit Snapline to use the line here"] = "退出 Snapline 后才能在这里使用晾衣绳",
        ["Press keys…"] = "请按键…",
        ["{0} is used by {1}"] = "{0} 已被“{1}”占用",
    };
}

/// <summary>XAML: <c>Content="{sh:T 'Save'}"</c>.</summary>
[MarkupExtensionReturnType(typeof(string))]
public sealed class TExtension(string text) : MarkupExtension
{
    public override object ProvideValue(IServiceProvider serviceProvider) => Loc.T(text);
}
