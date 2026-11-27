using System.Diagnostics;
using System.Drawing.Drawing2D;

namespace Kadr;

internal sealed record PaletteChoice(string Name, Action<Graphics, RectangleF> Draw, string? Caption = null, string? Shortcut = null)
{
    internal string Hint => Shortcut is null ? Name : $"{Name} ({Shortcut})";
}

internal sealed class PaletteHints : IDisposable
{
    private readonly ToolTip tip = new() { UseAnimation = false, UseFading = false };
    private readonly System.Windows.Forms.Timer delay = new() { Interval = 1000 };
    private GlyphButton? anchor;
    private bool shown;

    internal PaletteHints() => delay.Tick += (_, _) => Show();

    internal void Track(GlyphButton button)
    {
        button.MouseEnter += (_, _) => Begin(button);
        button.MouseLeave += (_, _) => End(button);
        button.MouseDown += (_, _) => End(button);
    }

    internal void SetText(GlyphButton button, string text)
    {
        if (button.AccessibleDescription == text) return;
        button.AccessibleDescription = text;
        if (anchor == button) Begin(button);
    }

    private void Begin(GlyphButton button)
    {
        Dismiss();
        anchor = button;
        delay.Start();
    }

    private void End(GlyphButton button)
    {
        if (anchor == button) Dismiss();
    }

    private void Show()
    {
        delay.Stop();
        if (anchor is not { Visible: true, IsHandleCreated: true } button ||
            button.AccessibleDescription is not { Length: > 0 } caption ||
            !button.ClientRectangle.Contains(button.PointToClient(Control.MousePosition))) return;

        Rectangle bounds = button.RectangleToScreen(button.ClientRectangle);
        Rectangle safe = Screen.FromRectangle(bounds).WorkingArea;
        int gap = (int)Math.Round(button.DeviceDpi / 16f);
        Size text = TextRenderer.MeasureText(caption, SystemFonts.StatusFont);
        int width = text.Width + gap * 2, height = text.Height + gap;
        int x = bounds.Right + gap;
        if (x + width > safe.Right) x = Math.Max(safe.Left, bounds.Left - gap - width);
        int y = Math.Clamp(bounds.Top + (bounds.Height - height) / 2, safe.Top, Math.Max(safe.Top, safe.Bottom - height));
        tip.Show(caption, button, button.PointToClient(new Point(x, y)));
        shown = true;
    }

    internal void Dismiss()
    {
        delay.Stop();
        if (shown && anchor is { IsHandleCreated: true } button) tip.Hide(button);
        shown = false;
        anchor = null;
    }

    public void Dispose()
    {
        Dismiss();
        delay.Dispose();
        tip.Dispose();
    }
}

internal static class Glyphs
{
    internal static readonly string[] ToolNames = ["Карандаш", "Маркер", "Текст", "Прямоугольник", "Овал", "Стрелка", "Линия"];
    internal static readonly string[] ColorNames = ["Белый", "Красный", "Зелёный", "Синий", "Фиолетовый", "Чёрный", "Жёлтый"];

    internal static void Tool(Graphics g, RectangleF r, Kadr.Tool tool)
    {
        GraphicsState state = g.Save();
        g.TranslateTransform(r.Left, r.Top);
        g.ScaleTransform(r.Width / 24, r.Height / 24);
        using var ink = new Pen(Color.White, 1.8f) { LineJoin = LineJoin.Round, StartCap = LineCap.Round, EndCap = LineCap.Round };
        switch (tool)
        {
            case Kadr.Tool.Pen:
                g.DrawPolygon(ink, [new PointF(4.2f, 19.8f), new PointF(5.5f, 14.3f), new PointF(16.6f, 3.2f),
                    new PointF(20.8f, 7.4f), new PointF(9.7f, 18.5f)]);
                g.DrawLine(ink, 14.9f, 5, 19, 9.1f);
                break;
            case Kadr.Tool.Marker:
                g.DrawPolygon(ink, [new PointF(5, 16), new PointF(7.4f, 11.2f), new PointF(16.5f, 3.1f),
                    new PointF(20.6f, 7.4f), new PointF(11.8f, 15.8f), new PointF(7.2f, 18.3f)]);
                g.DrawLine(ink, 3.7f, 21, 20.3f, 21);
                break;
            case Kadr.Tool.Text:
                using (var font = new Font("Segoe UI", 13, FontStyle.Bold, GraphicsUnit.Pixel))
                using (var center = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center })
                    g.DrawString("Aa", font, Brushes.White, new RectangleF(0, 0, 24, 24), center);
                break;
            case Kadr.Tool.Rectangle:
                using (GraphicsPath box = PaletteSurface.Rounded(new RectangleF(3, 6, 18, 12), 2))
                    g.DrawPath(ink, box);
                break;
            case Kadr.Tool.Ellipse:
                g.DrawEllipse(ink, 3, 5.2f, 18, 13.6f);
                break;
            case Kadr.Tool.Arrow:
                g.DrawLine(ink, 5, 19, 19, 5);
                g.DrawLines(ink, [new PointF(10, 5), new PointF(19, 5), new PointF(19, 14)]);
                break;
            case Kadr.Tool.Line:
                g.DrawLine(ink, 5, 19, 19, 5);
                break;
        }
        g.Restore(state);
    }

    internal static void ColorDot(Graphics g, RectangleF bounds, Color color)
    {
        RectangleF circle = RectangleF.Inflate(bounds, -2, -2);
        using var fill = new SolidBrush(color);
        using var border = new Pen(Color.FromArgb(130, 214, 222, 239), Math.Max(0.8f, bounds.Width / 27));
        g.FillEllipse(fill, circle);
        g.DrawEllipse(border, circle);
    }

    internal static void Stroke(Graphics g, RectangleF bounds, int width)
    {
        using var ink = new Pen(Color.White, Math.Max(2, width * 0.7f) * bounds.Width / 24)
            { StartCap = LineCap.Round, EndCap = LineCap.Round };
        float y = bounds.Top + bounds.Height / 2;
        g.DrawLine(ink, bounds.Left + 2, y, bounds.Right - 2, y);
    }
}

internal class PaletteSurface : Panel
{
    internal static readonly Color Fill = Color.FromArgb(29, 32, 39);
    protected readonly float ScaleFactor;
    private readonly int radius;

    internal PaletteSurface(float scale, int radius)
    {
        ScaleFactor = scale;
        this.radius = radius;
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer |
                 ControlStyles.ResizeRedraw, true);
        BackColor = Fill;
        Cursor = Cursors.Arrow;
    }

    protected override void OnSizeChanged(EventArgs e)
    {
        base.OnSizeChanged(e);
        if (Width < 2 || Height < 2) return;
        using GraphicsPath mask = Rounded(ClientRectangle, radius * ScaleFactor);
        Region? previous = Region;
        Region = new Region(mask);
        previous?.Dispose();
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        using GraphicsPath edge = Rounded(new RectangleF(0.5f, 0.5f, Width - 1, Height - 1), radius * ScaleFactor);
        using var border = new Pen(Color.FromArgb(74, 82, 97));
        e.Graphics.DrawPath(border, edge);
        base.OnPaint(e);
    }

    internal static GraphicsPath Rounded(RectangleF rect, float radius)
    {
        float diameter = Math.Min(radius * 2, Math.Min(rect.Width, rect.Height));
        var path = new GraphicsPath();
        path.AddArc(rect.Left, rect.Top, diameter, diameter, 180, 90);
        path.AddArc(rect.Right - diameter, rect.Top, diameter, diameter, 270, 90);
        path.AddArc(rect.Right - diameter, rect.Bottom - diameter, diameter, diameter, 0, 90);
        path.AddArc(rect.Left, rect.Bottom - diameter, diameter, diameter, 90, 90);
        path.CloseFigure();
        return path;
    }
}

internal sealed class GlyphButton : Button
{
    private Action<Graphics, RectangleF> drawIcon;
    private readonly string? caption;
    private readonly float scale;
    private bool hovered, pressed, keyboardHover;

    internal GlyphButton(float scale, PaletteChoice choice)
    {
        this.scale = scale;
        drawIcon = choice.Draw;
        caption = choice.Caption;
        AccessibleName = choice.Name;
        AccessibleDescription = choice.Hint;
        AccessibleRole = AccessibleRole.PushButton;
        FlatStyle = FlatStyle.Flat;
        FlatAppearance.BorderSize = 0;
        Cursor = Cursors.Arrow;
        BackColor = PaletteSurface.Fill;
        TabStop = false;
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer, true);
    }

    internal void SetIcon(Action<Graphics, RectangleF> draw)
    {
        drawIcon = draw;
        Invalidate();
    }

    internal void SetKeyboardHover(bool value)
    {
        keyboardHover = value;
        Invalidate();
    }

    protected override void OnMouseEnter(EventArgs e) { hovered = true; Invalidate(); base.OnMouseEnter(e); }
    protected override void OnMouseLeave(EventArgs e) { hovered = false; pressed = false; Invalidate(); base.OnMouseLeave(e); }
    protected override void OnMouseDown(MouseEventArgs e) { pressed = true; Invalidate(); base.OnMouseDown(e); }
    protected override void OnMouseUp(MouseEventArgs e) { pressed = false; Invalidate(); base.OnMouseUp(e); }
    protected override void OnEnabledChanged(EventArgs e) { base.OnEnabledChanged(e); Invalidate(); }

    protected override void OnPaint(PaintEventArgs e)
    {
        Graphics g = e.Graphics;
        g.Clear(PaletteSurface.Fill);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        if (Enabled && (hovered || keyboardHover || pressed))
        {
            using GraphicsPath shape = PaletteSurface.Rounded(RectangleF.Inflate(ClientRectangle, -0.5f, -0.5f), 7 * scale);
            using var tint = new SolidBrush(Color.FromArgb(pressed ? 72 : 49, pressed ? 81 : 56, pressed ? 99 : 71));
            g.FillPath(tint, shape);
        }
        float iconSize = 24 * scale;
        using var font = new Font("Segoe UI", 14 * scale, FontStyle.Regular, GraphicsUnit.Pixel);
        float groupWidth = caption is null ? iconSize : iconSize + 53 * scale;
        float x = (Width - groupWidth) / 2;
        drawIcon(g, new RectangleF(x, (Height - iconSize) / 2, iconSize, iconSize));
        if (caption is { } value)
            g.DrawString(value, font, Brushes.White, x + iconSize + 9 * scale, (Height - font.GetHeight(g)) / 2);
        if (!Enabled)
        {
            using var shade = new SolidBrush(Color.FromArgb(175, PaletteSurface.Fill));
            g.FillRectangle(shade, ClientRectangle);
        }
    }
}

internal sealed class ChoicePanel : PaletteSurface
{
    private readonly List<GlyphButton> buttons = [];
    private readonly System.Windows.Forms.Timer animation = new() { Interval = 15 };
    private readonly Stopwatch time = new();
    private Point anchor;
    private int highlighted;

    internal ChoicePanel(float scale, IReadOnlyList<PaletteChoice> rows, int current, Action<int> select,
        PaletteHints hints) : base(scale, 13)
    {
        highlighted = current;
        int padding = (int)Math.Round(7 * scale);
        int spacing = (int)Math.Round(2 * scale);
        int width = (int)Math.Round((rows[0].Caption is null ? 38 : 96) * scale);
        int height = (int)Math.Round(36 * scale);
        Size = new Size(width + 2 * padding, 2 * padding + rows.Count * height + (rows.Count - 1) * spacing);
        for (int i = 0; i < rows.Count; i++)
        {
            int index = i;
            var button = new GlyphButton(scale, rows[i])
            {
                Bounds = new Rectangle(padding, padding + i * (height + spacing), width, height)
            };
            button.Click += (_, _) => select(index);
            buttons.Add(button);
            Controls.Add(button);
            hints.Track(button);
        }
        animation.Tick += (_, _) =>
        {
            double progress = Math.Min(1, time.Elapsed.TotalMilliseconds / 145);
            Location = new Point(anchor.X, anchor.Y + (int)Math.Round(5 * ScaleFactor * Math.Pow(1 - progress, 3)));
            if (progress == 1) animation.Stop();
        };
    }

    internal void Open(Point point, bool animate)
    {
        anchor = point;
        Location = animate ? new Point(point.X, point.Y + (int)(5 * ScaleFactor)) : point;
        if (animate) { time.Restart(); animation.Start(); }
    }

    internal void MoveHighlight(int delta)
    {
        buttons[highlighted].SetKeyboardHover(false);
        highlighted = (highlighted + delta + buttons.Count) % buttons.Count;
        buttons[highlighted].SetKeyboardHover(true);
    }

    internal void PickHighlighted() => buttons[highlighted].PerformClick();

    protected override void Dispose(bool disposing)
    {
        if (disposing) animation.Dispose();
        base.Dispose(disposing);
    }
}

internal sealed class UndoToast : PaletteSurface
{
    private readonly System.Windows.Forms.Timer timer = new() { Interval = 150 };
    private readonly Stopwatch clock = Stopwatch.StartNew();

    internal UndoToast(float scale, int deleted, Action undo, Action expire) : base(scale, 10)
    {
        int Ui(int value) => (int)Math.Round(value * scale);
        Size = new Size(Ui(236), Ui(36));
        Cursor = Cursors.Hand;
        var message = new Label
        {
            Text = deleted == 1 ? "Пометка удалена" : "Пометки удалены",
            Bounds = new Rectangle(Ui(11), 0, Ui(110), Height),
            ForeColor = Color.White, TextAlign = ContentAlignment.MiddleLeft
        };
        var button = new Button
        {
            Text = "Отменить", AccessibleDescription = "Ctrl+Z",
            Bounds = new Rectangle(Ui(120), Ui(4), Ui(76), Height - Ui(8)),
            FlatStyle = FlatStyle.Flat, ForeColor = Color.FromArgb(192, 179, 255),
            BackColor = Fill, UseVisualStyleBackColor = false, TabStop = false, Cursor = Cursors.Hand
        };
        button.FlatAppearance.BorderSize = 0;
        var countdown = new Label
        {
            Text = "3 с", Bounds = new Rectangle(Ui(202), 0, Ui(25), Height),
            ForeColor = Color.FromArgb(180, 183, 195), TextAlign = ContentAlignment.MiddleCenter
        };
        Controls.AddRange([message, button, countdown]);
        void ActivateUndo()
        {
            if (clock.Elapsed.TotalSeconds < 3) undo();
            else expire();
        }
        void ClickSurface(object? sender, MouseEventArgs e)
        {
            if (e.Button == MouseButtons.Left) ActivateUndo();
        }
        MouseClick += ClickSurface;
        message.MouseClick += ClickSurface;
        countdown.MouseClick += ClickSurface;
        button.Click += (_, _) => ActivateUndo();
        timer.Tick += (_, _) =>
        {
            int seconds = (int)Math.Ceiling(3 - clock.Elapsed.TotalSeconds);
            if (seconds > 0) countdown.Text = $"{seconds} с";
            else expire();
        };
        timer.Start();
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing) timer.Dispose();
        base.Dispose(disposing);
    }
}

internal sealed class CopyToast : Form
{
    private readonly System.Windows.Forms.Timer timer = new() { Interval = 1800 };
    protected override bool ShowWithoutActivation => true;

    internal CopyToast(Screen screen)
    {
        AutoScaleMode = AutoScaleMode.None;
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        StartPosition = FormStartPosition.Manual;
        TopMost = true;
        Size = new Size(239, 43);
        Rectangle visible = screen.WorkingArea;
        Location = new Point(visible.Left + (visible.Width - Width) / 2, visible.Bottom - Height - 14);
        using GraphicsPath shape = PaletteSurface.Rounded(ClientRectangle, 12);
        Region = new Region(shape);
        var backdrop = new PaletteSurface(1, 12) { Dock = DockStyle.Fill };
        backdrop.Paint += (_, e) =>
        {
            using var font = new Font("Segoe UI", 13, FontStyle.Bold, GraphicsUnit.Pixel);
            using var green = new SolidBrush(Color.FromArgb(91, 215, 137));
            e.Graphics.FillEllipse(green, 15, 13, 17, 17);
            using var check = new Pen(PaletteSurface.Fill, 1.7f);
            e.Graphics.DrawLines(check, [new Point(19, 21), new Point(22, 24), new Point(28, 18)]);
            e.Graphics.DrawString("Скопировано в буфер", font, Brushes.White, 42, (Height - font.GetHeight(e.Graphics)) / 2);
        };
        Controls.Add(backdrop);
        timer.Tick += (_, _) => Close();
        Shown += (_, _) => timer.Start();
    }

    protected override CreateParams CreateParams
    {
        get
        {
            CreateParams parameters = base.CreateParams;
            parameters.ExStyle |= 0x08000080; // No activation; tool window.
            return parameters;
        }
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing) timer.Dispose();
        base.Dispose(disposing);
    }
}
