using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

namespace Kadr;

internal sealed class EditorWindow : Form
{
    private enum DragMode { None, Select, Move, Resize, Draw, ResizeMark, MoveMark }
    private static readonly Tool[] ToolOrder = [Tool.Pen, Tool.Marker, Tool.Rectangle, Tool.Ellipse,
        Tool.Arrow, Tool.Line, Tool.Text];
    private static readonly Dictionary<Keys, Tool> ToolShortcuts = new()
    {
        [Keys.T] = Tool.Text, [Keys.S] = Tool.Rectangle, [Keys.R] = Tool.Ellipse,
        [Keys.E] = Tool.Line, [Keys.A] = Tool.Arrow, [Keys.D] = Tool.Pen, [Keys.Q] = Tool.Marker
    };

    private readonly Bitmap desktop;
    private readonly Action<Screen> notifyCopy;
    private readonly List<Annotation> marks = [];
    private readonly Stack<Annotation[]> undo = [], redo = [];
    private readonly PaletteHints hints = new();
    private EditorSettings settings = EditorSettings.Load();
    private PaletteSurface? toolbar;
    private UndoToast? undoToast;
    private GlyphButton? toolButton, colorButton, strokeButton;
    private ChoicePanel? choices;
    private GlyphButton? choiceAnchor;
    private Rectangle selection, dragRect;
    private Rectangle previousCrop;
    private Point dragStart, resizeSide;
    private DragMode drag;
    private Annotation? draft, typing;
    private Annotation? annotationPreview;
    private int? selectedMark, editingTextIndex;
    private int annotationGrip;
    private TextBox? input;
    private float scale = 1;

    internal bool IsSaving { get; private set; }
    private bool HasSelection => selection.Width >= 8 && selection.Height >= 8;

    internal EditorWindow(Bitmap desktop, Rectangle screenBounds, Action<Screen> notifyCopy)
    {
        this.desktop = desktop;
        this.notifyCopy = notifyCopy;
        AutoScaleMode = AutoScaleMode.None;
        StartPosition = FormStartPosition.Manual;
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        TopMost = true;
        KeyPreview = true;
        Bounds = screenBounds;
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer |
                 ControlStyles.ResizeRedraw, true);
        Cursor = Cursors.Cross;
    }

    protected override void OnShown(EventArgs e)
    {
        base.OnShown(e);
        scale = DeviceDpi / 96f;
        BuildToolbar();
        if (settings.FullScreenCapture) SetSelection(ActiveDisplay());
        Focus();
    }

    protected override void OnDeactivate(EventArgs e)
    {
        hints.Dismiss();
        DismissUndoToast();
        base.OnDeactivate(e);
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        Graphics g = e.Graphics;
        g.DrawImageUnscaled(desktop, 0, 0);
        using var veil = new SolidBrush(Color.FromArgb(104, Color.Black));
        using var outside = new Region(ClientRectangle);
        outside.Exclude(selection);
        g.FillRegion(veil, outside);
        if (selection.Width < 1 || selection.Height < 1) return;

        g.SmoothingMode = SmoothingMode.AntiAlias;
        GraphicsState state = g.Save();
        g.SetClip(selection, CombineMode.Intersect);
        for (int index = 0; index < marks.Count; index++)
        {
            if (index == editingTextIndex) continue;
            Annotation mark = index == selectedMark ? annotationPreview ?? marks[index] : marks[index];
            mark.Draw(g);
        }
        draft?.Draw(g);
        if (typing is { } live && input is { } field)
            live.Draw(g, field.SelectionStart);
        DrawMarkSelection(g);
        g.Restore(state);
        using var border = new Pen(Color.White, 1.25f * scale);
        g.DrawRectangle(border, selection);
        if (!HasSelection) return;
        float size = 10 * scale;
        foreach ((Point point, _) in Handles())
        {
            using GraphicsPath handle = PaletteSurface.Rounded(new RectangleF(point.X - size / 2, point.Y - size / 2, size, size), 2 * scale);
            g.FillPath(Brushes.White, handle);
            using var edge = new Pen(Color.FromArgb(130, Color.Black));
            g.DrawPath(edge, handle);
        }
    }

    private void DrawMarks(Graphics graphics)
    {
        foreach (Annotation mark in marks) mark.Draw(graphics);
    }

    private void DrawMarkSelection(Graphics graphics)
    {
        if (selectedMark is not int index || typing is not null) return;
        Annotation mark = annotationPreview ?? marks[index];
        if (mark.Tool is Tool.Text or Tool.Pen)
        {
            RectangleF bounds = mark.Tool == Tool.Text ? mark.TextBounds() : mark.MovementBounds();
            RectangleF box = RectangleF.Inflate(bounds, Ui(3), Ui(2));
            using var outline = new Pen(Color.DodgerBlue, scale) { DashStyle = DashStyle.Dash };
            graphics.DrawRectangle(outline, box.X, box.Y, box.Width, box.Height);
        }
        float size = Ui(8);
        foreach (Point center in mark.Handles())
        {
            var handle = new RectangleF(center.X - size / 2, center.Y - size / 2, size, size);
            graphics.FillEllipse(Brushes.DodgerBlue, handle);
            graphics.DrawEllipse(Pens.White, handle);
        }
    }

    protected override void OnMouseDown(MouseEventArgs e)
    {
        base.OnMouseDown(e);
        if (e.Button != MouseButtons.Left) return;
        if (choices is not null) { DismissChoices(); return; }
        DismissUndoToast();
        CommitText();
        Focus();
        dragStart = Geometry.Clamp(e.Location, ClientRectangle);
        dragRect = selection;
        if (FindHandle(dragStart) is { } side)
        {
            selectedMark = null;
            drag = DragMode.Resize;
            resizeSide = side;
        }
        else if (OnBorder(dragStart))
        {
            selectedMark = null;
            drag = DragMode.Move;
        }
        else if (!HasSelection || !selection.Contains(dragStart))
        {
            selectedMark = null;
            drag = DragMode.Select;
            SetSelection(new Rectangle(dragStart, Size.Empty));
        }
        else if (FindMarkHandle(dragStart) is int grip)
        {
            annotationGrip = grip;
            drag = DragMode.ResizeMark;
        }
        else if (FindMark(dragStart) is int index)
        {
            selectedMark = index;
            Invalidate();
            if (marks[index].Tool == Tool.Text && e.Clicks >= 2)
            {
                BeginText(marks[index].Points[0], editing: index);
                return;
            }
            drag = DragMode.MoveMark;
            Cursor = Cursors.SizeAll;
        }
        else if (settings.Tool == Tool.Text)
        {
            selectedMark = null;
            BeginText(dragStart);
            return;
        }
        else
        {
            selectedMark = null;
            drag = DragMode.Draw;
            draft = NewMark(dragStart);
        }
        Capture = true;
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        base.OnMouseMove(e);
        Point point = Geometry.Clamp(e.Location, ClientRectangle);
        switch (drag)
        {
            case DragMode.Select:
                if (ModifierKeys.HasFlag(Keys.Shift)) point = Geometry.Square(dragStart, point, ClientRectangle);
                SetSelection(Geometry.Between(dragStart, point));
                break;
            case DragMode.Move:
                int x = Math.Clamp(dragRect.X + point.X - dragStart.X, 0, Math.Max(0, ClientSize.Width - dragRect.Width));
                int y = Math.Clamp(dragRect.Y + point.Y - dragStart.Y, 0, Math.Max(0, ClientSize.Height - dragRect.Height));
                SetSelection(new Rectangle(new Point(x, y), dragRect.Size));
                break;
            case DragMode.Resize:
                Point fixedPoint = new(resizeSide.X == -1 ? dragRect.Right : dragRect.Left,
                    resizeSide.Y == -1 ? dragRect.Bottom : dragRect.Top);
                Point moving = new(resizeSide.X == 0 ? dragRect.Right : point.X, resizeSide.Y == 0 ? dragRect.Bottom : point.Y);
                if (resizeSide.X != 0 && resizeSide.Y != 0 && ModifierKeys.HasFlag(Keys.Shift))
                    moving = Geometry.Square(fixedPoint, moving, ClientRectangle);
                SetSelection(Geometry.Between(fixedPoint, moving));
                break;
            case DragMode.ResizeMark when selectedMark is int index:
                ResizeMark(marks[index], point);
                break;
            case DragMode.MoveMark when selectedMark is int index:
                MoveMark(marks[index], point);
                break;
            case DragMode.Draw when draft is { } mark:
                if (mark.Tool is Tool.Rectangle or Tool.Ellipse || mark.HasEndpoints)
                {
                    if (ModifierKeys.HasFlag(Keys.Shift))
                        point = mark.HasEndpoints ? Geometry.AngleStep(dragStart, point, ClientRectangle)
                            : Geometry.Square(dragStart, point, ClientRectangle);
                    if (mark.Points.Count == 1) mark.Points.Add(point);
                    else mark.Points[1] = point;
                }
                else if (mark.Points[^1] != point) mark.Points.Add(point);
                Invalidate();
                break;
            default:
                UpdateIdleCursor(point);
                break;
        }
    }

    private void UpdateIdleCursor(Point point)
    {
        Cursor = FindHandle(point) is { } handle ? HandleCursor(handle) :
            OnBorder(point) ? Cursors.SizeAll :
            FindMarkHandle(point) is int grip && selectedMark is int selected
                ? MarkHandleCursor(marks[selected], grip) :
            FindMark(point).HasValue ? Cursors.SizeAll :
            settings.Tool == Tool.Text && selection.Contains(point) ? Cursors.IBeam : Cursors.Cross;
    }

    protected override void OnMouseUp(MouseEventArgs e)
    {
        base.OnMouseUp(e);
        if (e.Button != MouseButtons.Left || drag == DragMode.None) return;
        OnMouseMove(e);
        if (selectedMark is int index && annotationPreview is { } updated &&
            !updated.Points.SequenceEqual(marks[index].Points))
        {
            PushHistory();
            marks[index] = updated;
        }
        annotationPreview = null;
        if (draft is { CanCommit: true } mark) AddMark(mark);
        draft = null;
        drag = DragMode.None;
        Capture = false;
        Invalidate();
    }

    protected override void OnMouseCaptureChanged(EventArgs e)
    {
        base.OnMouseCaptureChanged(e);
        if (Capture || drag == DragMode.None) return;
        draft = null;
        annotationPreview = null;
        drag = DragMode.None;
        Invalidate();
    }

    private void SetSelection(Rectangle rectangle)
    {
        selection = Rectangle.Intersect(ClientRectangle, rectangle);
        PlaceToolbar();
        Invalidate();
    }

    private Rectangle ActiveDisplay()
    {
        Screen screen = HasSelection ? Screen.FromRectangle(RectangleToScreen(selection)) : Screen.FromPoint(MousePosition);
        return new Rectangle(PointToClient(screen.Bounds.Location), screen.Bounds.Size);
    }

    private void ToggleFullScreen()
    {
        Rectangle display = ActiveDisplay();
        bool expand = selection != display;
        DismissChoices();
        if (expand)
        {
            previousCrop = HasSelection ? selection : Rectangle.Empty;
            SetSelection(display);
        }
        else
        {
            SetSelection(previousCrop.IsEmpty ? Geometry.CenteredCrop(display) : previousCrop);
            previousCrop = Rectangle.Empty;
        }
        Apply(settings with { FullScreenCapture = expand });
    }

    private bool OnBorder(Point point)
    {
        if (!HasSelection) return false;
        int thickness = (int)Math.Ceiling(4 * scale);
        return Rectangle.Inflate(selection, thickness, thickness).Contains(point)
            && !Rectangle.Inflate(selection, -thickness, -thickness).Contains(point);
    }

    private Point? FindHandle(Point point)
    {
        if (!HasSelection) return null;
        float radius = 10 * scale;
        foreach ((Point center, Point side) in Handles())
            if (Math.Abs(center.X - point.X) <= radius && Math.Abs(center.Y - point.Y) <= radius) return side;
        return null;
    }

    private IEnumerable<(Point Center, Point Side)> Handles()
    {
        for (int y = -1; y <= 1; y++)
        for (int x = -1; x <= 1; x++)
        {
            if (x == 0 && y == 0) continue;
            yield return (new Point(selection.Left + (x + 1) * selection.Width / 2,
                selection.Top + (y + 1) * selection.Height / 2), new Point(x, y));
        }
    }

    private static Cursor HandleCursor(Point side) =>
        side.X == 0 ? Cursors.SizeNS : side.Y == 0 ? Cursors.SizeWE :
        side.X == side.Y ? Cursors.SizeNWSE : Cursors.SizeNESW;

    private int? FindMark(Point point)
    {
        if (!selection.Contains(point)) return null;
        for (int index = marks.Count - 1; index >= 0; index--)
            if (marks[index].HitTest(point, Ui(5))) return index;
        return null;
    }

    private int? FindMarkHandle(Point point)
    {
        if (selectedMark is not int index || typing is not null || !selection.Contains(point)) return null;
        Point[] handles = marks[index].Handles();
        int? nearest = null;
        int best = Ui(9) * Ui(9);
        for (int grip = 0; grip < handles.Length; grip++)
        {
            int dx = handles[grip].X - point.X, dy = handles[grip].Y - point.Y;
            int distance = dx * dx + dy * dy;
            if (distance > best) continue;
            nearest = grip;
            best = distance;
        }
        return nearest;
    }

    private static Cursor MarkHandleCursor(Annotation mark, int grip) =>
        mark.HasEndpoints ? Cursors.Cross : grip % 2 == 0 ? Cursors.SizeNWSE : Cursors.SizeNESW;

    private void ResizeMark(Annotation original, Point point)
    {
        if (point == dragStart)
        {
            annotationPreview = null;
            Invalidate();
            return;
        }
        Point[] handles = original.Handles();
        Point center = handles[annotationGrip];
        var target = Geometry.Clamp(new Point(center.X + point.X - dragStart.X, center.Y + point.Y - dragStart.Y),
            ClientRectangle);
        Annotation updated = original.Copy();
        annotationPreview = null;
        Invalidate();
        if (original.HasEndpoints)
        {
            if (ModifierKeys.HasFlag(Keys.Shift))
                target = Geometry.AngleStep(original.Points[1 - annotationGrip], target, ClientRectangle);
            updated.Points[annotationGrip] = target;
            if (!updated.CanCommit) return;
        }
        else
        {
            Point anchor = handles[(annotationGrip + 2) % handles.Length];
            if (ModifierKeys.HasFlag(Keys.Shift)) target = Geometry.Square(anchor, target, ClientRectangle);
            Rectangle box = Geometry.Between(anchor, target);
            if (box.Width < 2 || box.Height < 2) return;
            updated.Points[0] = box.Location;
            updated.Points[1] = new Point(box.Right, box.Bottom);
        }
        annotationPreview = updated;
    }

    private void MoveMark(Annotation original, Point point)
    {
        RectangleF box = original.MovementBounds();
        int dx = (int)Math.Clamp(point.X - dragStart.X, Math.Min(0, selection.Left - box.Left),
            Math.Max(0, selection.Right - box.Right));
        int dy = (int)Math.Clamp(point.Y - dragStart.Y, Math.Min(0, selection.Top - box.Top),
            Math.Max(0, selection.Bottom - box.Bottom));
        Annotation updated = original.Copy();
        var offset = new Size(dx, dy);
        for (int index = 0; index < updated.Points.Count; index++) updated.Points[index] += offset;
        annotationPreview = updated;
        Invalidate();
    }

    private Annotation NewMark(Point origin)
    {
        float fontPixels = EditorSettings.TextSizes[settings.TextIndex] * DeviceDpi / 72f;
        Color ink = EditorSettings.Colors[settings.ColorIndex];
        return new Annotation(settings.Tool, ink, EditorSettings.Strokes[settings.StrokeIndex] * scale, origin)
        {
            FontPixels = fontPixels,
            TextSizeIndex = settings.TextIndex
        };
    }

    private void BeginText(Point point, int? editing = null)
    {
        Annotation mark = editing is int index ? marks[index].Copy() : NewMark(point);
        typing = mark;
        editingTextIndex = editing;
        // A native text control takes keyboard input, while the canvas renders it with the final appearance.
        var field = new TextBox
        {
            Multiline = true, AcceptsReturn = true, BorderStyle = BorderStyle.None,
            Location = point, Size = new Size(1, 1), Region = new Region(Rectangle.Empty),
            TabStop = false, AccessibleName = "Текст на снимке", Text = mark.Text
        };
        input = field;
        field.KeyDown += (_, e) =>
        {
            if (e.KeyData != Keys.Enter) return;
            e.SuppressKeyPress = true;
            CommitText();
        };
        field.TextChanged += (_, _) => { mark.Text = field.Text; Invalidate(); };
        field.KeyUp += (_, _) => Invalidate();
        Controls.Add(field);
        field.Focus();
        field.SelectionStart = field.TextLength;
        Invalidate();
    }

    private void CommitText()
    {
        Annotation? mark = typing;
        int? editing = editingTextIndex;
        EndTextInput();
        if (mark is not null)
        {
            bool empty = string.IsNullOrWhiteSpace(mark.Text);
            if (editing is int index && marks[index].Text != mark.Text)
            {
                PushHistory();
                if (empty)
                {
                    marks.RemoveAt(index);
                    selectedMark = null;
                    if (HasSelection) ShowUndoToast(1);
                }
                else marks[index] = mark;
            }
            else if (editing is null && !empty) AddMark(mark);
        }
        Invalidate();
    }

    private void EndTextInput()
    {
        typing = null;
        editingTextIndex = null;
        if (input is not { } field) return;
        input = null;
        Focus();
        Controls.Remove(field);
        field.Dispose();
    }

    private void AddMark(Annotation mark)
    {
        PushHistory();
        marks.Add(mark);
    }

    private void PushHistory()
    {
        DismissUndoToast();
        undo.Push(marks.ToArray());
        redo.Clear();
    }

    private void Undo()
    {
        RestoreHistory(undo, redo);
    }

    private void Redo()
    {
        RestoreHistory(redo, undo);
    }

    private void RestoreHistory(Stack<Annotation[]> source, Stack<Annotation[]> destination)
    {
        if (!source.TryPop(out Annotation[]? snapshot)) return;
        DismissUndoToast();
        destination.Push(marks.ToArray());
        marks.Clear();
        marks.AddRange(snapshot);
        selectedMark = null;
        Invalidate();
    }

    protected override bool ProcessCmdKey(ref Message message, Keys key)
    {
        switch (key)
        {
            case Keys.Escape:
                if ((message.LParam.ToInt64() & (1L << 30)) == 0) HandleEscape();
                return true;
            case Keys.Control | Keys.C: Export(save: false); return true;
            case Keys.Control | Keys.S: Export(save: true); return true;
            case Keys.Control | Keys.Z when input is null: Undo(); return true;
            case Keys.Control | Keys.Shift | Keys.Z when input is null: Redo(); return true;
            case Keys.Delete or Keys.Back when input is null && choices is null && drag == DragMode.None
                && HasSelection:
                // Repeating after a selected deletion must not clear the remaining marks.
                if ((message.LParam.ToInt64() & (1L << 30)) == 0) DeleteMarks();
                return true;
        }
        if (ChoiceKey(key)) return true;
        if (input is null && drag == DragMode.None && EditorShortcut(key, message.LParam)) return true;
        return base.ProcessCmdKey(ref message, key);
    }

    private void DeleteMarks()
    {
        if (marks.Count == 0) return;
        PushHistory();
        int deleted;
        if (selectedMark is int index)
        {
            marks.RemoveAt(index);
            deleted = 1;
        }
        else
        {
            deleted = marks.Count;
            marks.Clear();
        }
        selectedMark = null;
        UpdateIdleCursor(PointToClient(MousePosition));
        Invalidate();
        ShowUndoToast(deleted);
    }

    private bool EditorShortcut(Keys key, nint details)
    {
        if (SizeShortcut(key)) return true;
        if (key == Keys.F)
        {
            if ((details.ToInt64() & (1L << 30)) == 0) ToggleFullScreen();
            return true;
        }
        int code = (int)key;
        int color = code >= (int)Keys.NumPad1 ? code - (int)Keys.NumPad1 : code - (int)Keys.D1;
        if (color >= 0 && color < EditorSettings.ColorOrder.Length)
        {
            DismissChoices();
            Apply(settings with { ColorIndex = EditorSettings.ColorOrder[color] });
            return true;
        }
        if (!ToolShortcuts.TryGetValue(key, out Tool selected)) return false;
        DismissChoices();
        Apply(settings with { Tool = selected });
        return true;
    }

    private bool SizeShortcut(Keys key)
    {
        const Keys shiftedPlus = Keys.Oemplus | Keys.Shift;
        const Keys backTab = Keys.Tab | Keys.Shift;
        int step = key switch
        {
            Keys.Oemplus or shiftedPlus or Keys.Add or Keys.Tab => 1,
            Keys.OemMinus or Keys.Subtract or backTab => -1,
            _ => 0
        };
        if (step == 0) return false;
        StepSize(step, key is Keys.Tab or backTab);
        return true;
    }

    private void StepSize(int step, bool wraps)
    {
        bool textMode = settings.Tool == Tool.Text;
        int count = textMode ? EditorSettings.TextSizes.Length : EditorSettings.Strokes.Length;
        int current = StrokeIndex();
        int next = wraps ? (current + step + count) % count : Math.Clamp(current + step, 0, count - 1);
        DismissChoices();
        if (next != current) Apply(textMode ? settings with { TextIndex = next } : settings with { StrokeIndex = next });
    }

    private void HandleEscape()
    {
        if (choices is not null)
        {
            DismissChoices();
        }
        else if (input is not null)
        {
            EndTextInput();
            Invalidate();
        }
        else if (drag != DragMode.None)
        {
            DragMode canceled = drag;
            drag = DragMode.None;
            draft = null;
            annotationPreview = null;
            Capture = false;
            if (canceled is DragMode.Select or DragMode.Move or DragMode.Resize) SetSelection(dragRect);
            UpdateIdleCursor(PointToClient(MousePosition));
            Invalidate();
        }
        else
        {
            Close();
        }
    }

    protected override bool ProcessDialogKey(Keys keyData)
    {
        const Keys backTab = Keys.Tab | Keys.Shift;
        if (input is null && drag == DragMode.None && keyData is Keys.Tab or backTab) return SizeShortcut(keyData);
        return ChoiceKey(keyData) || base.ProcessDialogKey(keyData);
    }

    protected override void OnKeyPress(KeyPressEventArgs e)
    {
        if (input is null && drag == DragMode.None && e.KeyChar is '+' or '-' or '−')
        {
            StepSize(e.KeyChar == '+' ? 1 : -1, wraps: false);
            e.Handled = true;
        }
        base.OnKeyPress(e);
    }

    private bool ChoiceKey(Keys key)
    {
        if (choices is null) return false;
        switch (key)
        {
            case Keys.Up: choices.MoveHighlight(-1); return true;
            case Keys.Down: choices.MoveHighlight(1); return true;
            case Keys.Space or Keys.Enter: choices.PickHighlighted(); return true;
            default: return false;
        }
    }

    private void BuildToolbar()
    {
        var bar = new PaletteSurface(scale, 12) { Size = new Size(Ui(134), Ui(44)), Visible = false };
        toolbar = bar;
        toolButton = AddButton(bar, 8, ToolChoice(settings.Tool), ShowTools);
        colorButton = AddButton(bar, 49, ColorChoice(settings.ColorIndex), ShowColors);
        strokeButton = AddButton(bar, 90, StrokeChoice(StrokeIndex()), ShowStrokes);
        bar.MouseDown += (_, _) => DismissChoices();
        Controls.Add(bar);
        bar.BringToFront();
        RefreshToolbar();
    }

    private int Ui(float pixels) => (int)Math.Round(pixels * scale);

    private GlyphButton AddButton(PaletteSurface bar, int x, PaletteChoice choice, Action<GlyphButton> action)
    {
        var button = new GlyphButton(scale, choice with { Caption = null })
        {
            Bounds = new Rectangle(Ui(x), Ui(4), Ui(36), Ui(36))
        };
        button.Click += (_, _) => action(button);
        bar.Controls.Add(button);
        hints.Track(button);
        return button;
    }

    private void PlaceToolbar()
    {
        if (toolbar is null) return;
        if (!HasSelection)
        {
            DismissChoices();
            hints.Dismiss();
            DismissUndoToast(reposition: false);
            toolbar.Hide();
            return;
        }
        Rectangle crop = RectangleToScreen(selection);
        Screen screen = Screen.FromPoint(new Point(crop.Left + crop.Width / 2, crop.Bottom - 1));
        Rectangle safe = screen.WorkingArea;
        int margin = Ui(8), gap = Ui(15);
        int minX = safe.Left + margin, minY = safe.Top + margin;
        int maxX = Math.Max(minX, safe.Right - toolbar.Width - margin);
        int maxY = Math.Max(minY, safe.Bottom - toolbar.Height - margin);
        int x = crop.Left + (crop.Width - toolbar.Width) / 2;
        int below = crop.Bottom + gap;
        int above = crop.Top - gap - toolbar.Height;
        int y = below <= maxY ? below : above >= minY ? above : crop.Bottom - gap - toolbar.Height;
        int toastGap = Ui(6);
        int reserve = undoToast is { } toast ? toast.Height + toastGap : 0;
        Point location = PointToClient(new Point(Math.Clamp(x, minX, maxX),
            Math.Clamp(y, minY, Math.Max(minY, maxY - reserve))));
        if (location != toolbar.Location)
        {
            hints.Dismiss();
            toolbar.Location = location;
        }
        if (!toolbar.Visible) toolbar.Show();
        if (undoToast is { } undoHint)
        {
            Rectangle bar = toolbar.RectangleToScreen(toolbar.ClientRectangle);
            int hintX = bar.Left + (bar.Width - undoHint.Width) / 2;
            hintX = Math.Clamp(hintX, safe.Left + margin, Math.Max(safe.Left + margin, safe.Right - undoHint.Width - margin));
            undoHint.Location = PointToClient(new Point(hintX, bar.Bottom + toastGap));
        }
    }

    private void ShowUndoToast(int deleted)
    {
        var toast = new UndoToast(scale, deleted, () =>
        {
            if (input is not null || drag != DragMode.None) return;
            Undo();
            Focus();
        }, () => DismissUndoToast());
        undoToast = toast;
        Controls.Add(toast);
        PlaceToolbar();
        toast.BringToFront();
    }

    private void DismissUndoToast(bool reposition = true)
    {
        if (undoToast is not { } toast) return;
        undoToast = null;
        toast.Dispose();
        if (reposition) PlaceToolbar();
    }

    private static PaletteChoice ToolChoice(Tool tool)
    {
        Keys key = ToolShortcuts.FirstOrDefault(entry => entry.Value == tool).Key;
        return new PaletteChoice(Glyphs.ToolNames[(int)tool], (g, rect) => Glyphs.Tool(g, rect, tool),
            Shortcut: key == Keys.None ? null : key.ToString());
    }

    private static PaletteChoice ColorChoice(int index) =>
        new(Glyphs.ColorNames[index], (g, rect) => Glyphs.ColorDot(g, rect, EditorSettings.Colors[index]),
            Shortcut: (Array.IndexOf(EditorSettings.ColorOrder, index) + 1).ToString());

    private PaletteChoice StrokeChoice(int index)
    {
        int width = EditorSettings.Strokes[index];
        int size = settings.Tool == Tool.Text ? EditorSettings.TextSizes[index] : width;
        string caption = settings.Tool == Tool.Text ? $"{size} pt" : size.ToString();
        return new PaletteChoice($"{size} pt", (g, rect) => Glyphs.Stroke(g, rect, width), caption);
    }

    private int StrokeIndex() => settings.Tool == Tool.Text ? settings.TextIndex : settings.StrokeIndex;
    private void ShowTools(GlyphButton button) =>
        ShowChoices(button, ToolOrder.Select(ToolChoice).ToArray(), Array.IndexOf(ToolOrder, settings.Tool),
            index => Apply(settings with { Tool = ToolOrder[index] }));
    private void ShowColors(GlyphButton button) =>
        ShowChoices(button, EditorSettings.ColorOrder.Select(ColorChoice).ToArray(),
            Array.IndexOf(EditorSettings.ColorOrder, settings.ColorIndex),
            index => Apply(settings with { ColorIndex = EditorSettings.ColorOrder[index] }));
    private void ShowStrokes(GlyphButton button) =>
        ShowChoices(button, Enumerable.Range(0, EditorSettings.Strokes.Length).Select(StrokeChoice).ToArray(), StrokeIndex(),
            index => Apply(settings.Tool == Tool.Text ? settings with { TextIndex = index } : settings with { StrokeIndex = index }));

    private void ShowChoices(GlyphButton anchor, PaletteChoice[] rows, int current, Action<int> select)
    {
        bool alreadyOpen = choiceAnchor == anchor;
        DismissChoices();
        hints.Dismiss();
        if (alreadyOpen) return;
        choiceAnchor = anchor;
        var panel = new ChoicePanel(scale, rows, current, index => { DismissChoices(); select(index); Focus(); }, hints);
        choices = panel;
        Rectangle button = anchor.RectangleToScreen(anchor.ClientRectangle);
        Rectangle safe = Screen.FromRectangle(button).WorkingArea;
        int left = Math.Clamp(button.Left + (button.Width - panel.Width) / 2, safe.Left, Math.Max(safe.Left, safe.Right - panel.Width));
        int top = Math.Max(safe.Top, button.Top - panel.Height - Ui(8));
        panel.Open(PointToClient(new Point(left, top)), SystemInformation.IsMenuAnimationEnabled);
        Controls.Add(panel);
        panel.BringToFront();
    }

    private void DismissChoices()
    {
        ChoicePanel? panel = choices;
        if (panel is null) return;
        hints.Dismiss();
        choices = null;
        choiceAnchor = null;
        Controls.Remove(panel);
        panel.Dispose();
    }

    private void Apply(EditorSettings value)
    {
        CommitText();
        settings = value;
        settings.Save();
        RefreshToolbar();
    }

    private void RefreshToolbar()
    {
        UpdateButton(toolButton!, ToolChoice(settings.Tool), "Инструмент");
        UpdateButton(colorButton!, ColorChoice(settings.ColorIndex), "Цвет");
        bool textMode = settings.Tool == Tool.Text;
        var stroke = StrokeChoice(StrokeIndex()) with { Shortcut = "+ / − / Tab / Shift+Tab" };
        UpdateButton(strokeButton!, stroke, textMode ? "Размер текста" : "Толщина кисти");
    }

    private void UpdateButton(GlyphButton button, PaletteChoice choice, string label)
    {
        button.SetIcon(choice.Draw);
        button.AccessibleName = $"{label} · {choice.Name}";
        hints.SetText(button, $"{label} · {choice.Hint}");
    }

    private Bitmap RenderSelection()
    {
        var image = new Bitmap(selection.Width, selection.Height, PixelFormat.Format32bppArgb);
        using Graphics graphics = Graphics.FromImage(image);
        graphics.DrawImage(desktop, new Rectangle(Point.Empty, image.Size), selection, GraphicsUnit.Pixel);
        graphics.SmoothingMode = SmoothingMode.AntiAlias;
        graphics.TranslateTransform(-selection.X, -selection.Y);
        DrawMarks(graphics);
        return image;
    }

    private void Export(bool save)
    {
        DismissChoices();
        if (!HasSelection || IsSaving) return;
        CommitText();
        using Bitmap image = RenderSelection();
        using var encoded = new MemoryStream();
        image.Save(encoded, ImageFormat.Png);
        byte[] png = encoded.ToArray();
        if (save && !ChooseAndSave(png)) return;

        try
        {
            using var pngStream = new MemoryStream(png, writable: false);
            var contents = new DataObject();
            contents.SetData("PNG", autoConvert: false, pngStream);
            contents.SetImage(image);
            Clipboard.SetDataObject(contents, copy: true, retryTimes: 8, retryDelay: 50);
        }
        catch (ExternalException)
        {
            MessageBox.Show(this, save ? "Файл сохранён, но буфер обмена занят." : "Буфер обмена занят. Попробуйте ещё раз.",
                "Shooter MF", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            if (save) Close();
            return;
        }

        Screen screen = Screen.FromRectangle(RectangleToScreen(selection));
        Close();
        notifyCopy(screen);
    }

    private bool ChooseAndSave(byte[] png)
    {
        IsSaving = true;
        try
        {
            using var dialog = new SaveFileDialog
            {
                Title = "Сохранить скриншот",
                Filter = "Изображение PNG (*.png)|*.png",
                DefaultExt = "png", AddExtension = true, OverwritePrompt = true,
                InitialDirectory = Native.Downloads(),
                FileName = $"Shooter MF {DateTime.Now:yyyy-MM-dd HH.mm.ss}.png"
            };
            if (dialog.ShowDialog(this) != DialogResult.OK) return false;
            WritePng(dialog.FileName, png);
            return true;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            MessageBox.Show(this, $"Не удалось сохранить скриншот.\n\n{error.Message}",
                "Shooter MF", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            return false;
        }
        finally { IsSaving = false; }
    }

    private static void WritePng(string path, byte[] png)
    {
        string temp = Path.Combine(Path.GetDirectoryName(path)!, $".kadr-{Guid.NewGuid():N}.tmp");
        try
        {
            File.WriteAllBytes(temp, png);
            File.Move(temp, path, overwrite: true);
        }
        finally
        {
            try { File.Delete(temp); }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
        }
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            DismissUndoToast(reposition: false);
            desktop.Dispose();
            hints.Dispose();
        }
        base.Dispose(disposing);
    }
}
