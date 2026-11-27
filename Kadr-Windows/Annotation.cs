using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.Text.Json;

namespace Kadr;

internal enum Tool { Pen, Marker, Text, Rectangle, Ellipse, Arrow, Line }

internal sealed record EditorSettings(Tool Tool = Tool.Rectangle, int ColorIndex = 1, int StrokeIndex = 1, int TextIndex = 1,
    bool FullScreenCapture = false)
{
    internal static readonly Color[] Colors = [Color.White, Color.FromArgb(255, 69, 62), Color.FromArgb(52, 204, 82),
        Color.FromArgb(42, 133, 255), Color.FromArgb(190, 86, 232), Color.Black, Color.FromArgb(255, 204, 0)];
    internal static readonly int[] ColorOrder = [1, 2, 3, 4, 6, 5, 0];
    internal static readonly int[] Strokes = [2, 4, 8];
    internal static readonly int[] TextSizes = [16, 24, 36];
    private static readonly string FilePath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Kadr", "settings.json");

    internal static EditorSettings Load()
    {
        try
        {
            if (File.Exists(FilePath) && JsonSerializer.Deserialize<EditorSettings>(File.ReadAllText(FilePath)) is { } settings)
                return new EditorSettings(Enum.IsDefined(settings.Tool) ? settings.Tool : Tool.Rectangle,
                    Math.Clamp(settings.ColorIndex, 0, Colors.Length - 1), Math.Clamp(settings.StrokeIndex, 0, 2),
                    Math.Clamp(settings.TextIndex, 0, 2), settings.FullScreenCapture);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException) { }
        return new EditorSettings();
    }

    internal void Save()
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(FilePath)!);
            string temporary = FilePath + ".tmp";
            File.WriteAllText(temporary, JsonSerializer.Serialize(this));
            File.Move(temporary, FilePath, overwrite: true);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
    }
}

internal sealed class Annotation(Tool tool, Color color, float width, Point start, uint? brushSeed = null)
{
    private readonly uint textureSeed = brushSeed ?? (uint)Random.Shared.NextInt64(0, 1L << 32);
    internal Tool Tool { get; } = tool;
    internal Color Color { get; } = color;
    internal float Width { get; } = width;
    internal List<Point> Points { get; } = [start];
    internal string Text { get; set; } = "";
    internal float FontPixels { get; init; } = 32;
    internal int TextSizeIndex { get; init; } = 1;
    internal bool HasEndpoints => Tool is Tool.Arrow or Tool.Line;
    internal bool CanCommit => !HasEndpoints || SegmentLength >= 2;
    internal Rectangle ShapeBounds => Geometry.Between(Points[0], Points[^1]);

    internal Annotation Copy()
    {
        var copy = new Annotation(Tool, Color, Width, Points[0], textureSeed)
        {
            Text = Text, FontPixels = FontPixels, TextSizeIndex = TextSizeIndex
        };
        copy.Points.AddRange(Points.Skip(1));
        return copy;
    }

    internal RectangleF TextBounds()
    {
        using var font = TextFont();
        using var format = TextFormat();
        using var path = TextPath(font, format, font.GetHeight(96));
        return path.PointCount == 0 ? RectangleF.Empty : path.GetBounds();
    }

    internal RectangleF MovementBounds()
    {
        if (Tool == Tool.Text) return TextBounds();
        if (Tool == Tool.Pen) return RectangleF.Inflate(PencilBounds(), Width, Width);
        RectangleF bounds = ShapeBounds;
        if (Tool == Tool.Arrow && CanCommit)
        {
            (PointF left, PointF right) = ArrowHead(Points[0], Points[^1]);
            using var head = new GraphicsPath();
            head.AddLines([left, Points[^1], right]);
            bounds = RectangleF.Union(bounds, head.GetBounds());
        }
        float margin = Tool == Tool.Marker ? Width / 2 : Width;
        return RectangleF.Inflate(bounds, margin, margin);
    }

    private RectangleF PencilBounds() => RectangleF.FromLTRB(
        Points.Min(point => point.X), Points.Min(point => point.Y),
        Points.Max(point => point.X), Points.Max(point => point.Y));

    internal Point[] Handles()
    {
        if (HasEndpoints) return [Points[0], Points[^1]];
        if (Tool is not (Tool.Rectangle or Tool.Ellipse)) return [];
        Rectangle box = ShapeBounds;
        return [box.Location, new Point(box.Right, box.Top), new Point(box.Right, box.Bottom),
            new Point(box.Left, box.Bottom)];
    }

    internal bool HitTest(Point point, float margin)
    {
        if (Tool == Tool.Text)
            return RectangleF.Inflate(TextBounds(), margin, margin).Contains(point);
        if (Tool == Tool.Pen) return HitPencil(point, Width * .65f + margin);
        using var path = new GraphicsPath();
        switch (Tool)
        {
            case Tool.Rectangle when ShapeBounds.Width > 0 && ShapeBounds.Height > 0:
                path.AddRectangle(ShapeBounds);
                break;
            case Tool.Ellipse when ShapeBounds.Width > 0 && ShapeBounds.Height > 0:
                path.AddEllipse(ShapeBounds);
                break;
            case Tool.Arrow when CanCommit:
                (PointF left, PointF right) = ArrowHead(Points[0], Points[^1]);
                path.AddLines([left, Points[^1], right]);
                path.StartFigure();
                path.AddLine(Points[0], Points[^1]);
                break;
            case Tool.Line when CanCommit:
                path.AddLine(Points[0], Points[^1]);
                break;
            default:
                return false;
        }
        using var pen = new Pen(Color.Black, Width + 2 * margin) { LineJoin = LineJoin.Round };
        return path.IsOutlineVisible(point, pen);
    }

    private bool HitPencil(Point point, float radius)
    {
        if (!RectangleF.Inflate(PencilBounds(), radius, radius).Contains(point)) return false;
        if (Points.Count == 1)
        {
            float dx = point.X - Points[0].X, dy = point.Y - Points[0].Y;
            return dx * dx + dy * dy <= radius * radius;
        }
        using var path = new GraphicsPath();
        path.AddLines(new ChalkStroke(Width).PencilCenterline(Points).ToArray());
        using var pen = new Pen(Color.Black, 2 * radius)
            { LineJoin = LineJoin.Round, StartCap = LineCap.Round, EndCap = LineCap.Round };
        return path.IsOutlineVisible(point, pen);
    }

    private float SegmentLength
    {
        get
        {
            float dx = Points[^1].X - Points[0].X;
            float dy = Points[^1].Y - Points[0].Y;
            return MathF.Sqrt(dx * dx + dy * dy);
        }
    }

    internal void Draw(Graphics graphics, int caret = -1)
    {
        Point origin = Points[0];
        Point end = Points[^1];
        if (Tool == Tool.Text)
        {
            DrawText(graphics, origin, caret);
            return;
        }
        if (Tool != Tool.Marker)
        {
            DrawChalk(graphics, origin, end);
            return;
        }
        Color ink = Color.FromArgb(85, Color);
        float thickness = Math.Max(12, Width * 4);
        using var pen = new Pen(ink, thickness) { LineJoin = LineJoin.Round };
        if (Points.Count > 1)
        {
            graphics.DrawLines(pen, Points.ToArray());
        }
        else
        {
            using var brush = new SolidBrush(ink);
            graphics.FillEllipse(brush, origin.X - thickness / 2, origin.Y - thickness / 2, thickness, thickness);
        }
    }

    private void DrawChalk(Graphics graphics, Point origin, Point end)
    {
        Rectangle box = ShapeBounds;
        if (!CanCommit || (Tool is Tool.Rectangle or Tool.Ellipse && (box.Width == 0 || box.Height == 0))) return;
        var brush = new ChalkStroke(Width, textureSeed);
        PointF[][] strokes;
        switch (Tool)
        {
            case Tool.Pen: strokes = brush.Pencil(Points); break;
            case Tool.Rectangle: strokes = [brush.Rectangle(box)]; break;
            case Tool.Ellipse: strokes = [brush.Oval(box)]; break;
            case Tool.Arrow:
                (PointF left, PointF right) = ArrowHead(origin, end);
                strokes = brush.Arrow(origin, end, left, right);
                break;
            case Tool.Line: strokes = brush.Line(origin, end); break;
            default: return;
        }
        using var silhouette = new GraphicsPath(FillMode.Winding);
        foreach (PointF[] stroke in strokes)
        {
            if (stroke.Length >= 3) silhouette.AddPolygon(stroke);
        }
        if (Tool == Tool.Pen && silhouette.PointCount == 0)
            silhouette.AddEllipse(origin.X - Width / 2, origin.Y - Width / 2, Width, Width);
        AnnotationShadow.Draw(graphics, silhouette, ambientRadius: 2, ambient: 18);
        using var ink = new SolidBrush(Color);
        graphics.FillPath(ink, silhouette);
    }

    private (PointF Left, PointF Right) ArrowHead(Point origin, Point tip)
    {
        float length = SegmentLength;
        float dx = (tip.X - origin.X) / length;
        float dy = (tip.Y - origin.Y) / length;
        float headLength = Math.Min(length * 0.54f, Math.Max(13, Width * 4.05f));
        float halfHead = headLength * 0.35f;
        var headBase = new PointF(tip.X - dx * headLength, tip.Y - dy * headLength);
        return (new PointF(headBase.X - dy * halfHead, headBase.Y + dx * halfHead),
            new PointF(headBase.X + dy * halfHead, headBase.Y - dx * halfHead));
    }

    private void DrawText(Graphics graphics, Point origin, int caret)
    {
        using var font = TextFont();
        using var format = TextFormat();
        float lineHeight = font.GetHeight(graphics);
        using var path = TextPath(font, format, lineHeight);
        if (path.PointCount > 0)
        {
            AnnotationShadow.Draw(graphics, path, ambientRadius: 3, ambient: 16);
            using var fill = new SolidBrush(Color);
            graphics.FillPath(fill, path);
        }

        if (caret >= 0)
        {
            string[] prefix = Text[..Math.Min(caret, Text.Length)].Replace("\r", "").Split('\n');
            float x = origin.X + (prefix[^1].Length == 0 ? 0 : graphics.MeasureString(prefix[^1], font, PointF.Empty, format).Width);
            float y = origin.Y + (prefix.Length - 1) * lineHeight;
            using var cursor = new Pen(Color, 1.2f);
            graphics.DrawLine(cursor, x, y + 2, x, y + lineHeight);
        }
    }

    private Font TextFont() => new(GeologicaFont.ForSize(TextSizeIndex, FontPixels).Family,
        FontPixels, FontStyle.Regular, GraphicsUnit.Pixel);

    private sealed class GeologicaFont
    {
        private static readonly Dictionary<(int SizeIndex, float Pixels), GeologicaFont> cache = [];
        private readonly PrivateFontCollection fonts = new();
        private readonly byte[] fontData;
        internal FontFamily Family { get; }

        internal static GeologicaFont ForSize(int sizeIndex, float pixels)
        {
            var key = (sizeIndex, Pixels: sizeIndex == 0 ? 0 : pixels);
            if (!cache.TryGetValue(key, out GeologicaFont? face))
            {
                face = new GeologicaFont(key.Pixels, sizeIndex);
                cache.Add(key, face);
            }
            return face;
        }

        private unsafe GeologicaFont(float pixels, int spacing)
        {
            const string filename = "Geologica-Medium.ttf";
            using Stream stream = typeof(Annotation).Assembly.GetManifestResourceStream(filename)
                ?? throw new InvalidOperationException($"Missing embedded font: {filename}");
            // GDI+ can retain the pointer, so keep the buffer pinned for the life of the collection.
            fontData = GC.AllocateArray<byte>(checked((int)stream.Length), pinned: true);
            stream.ReadExactly(fontData);
            if (spacing != 0) FontTracking.Adjust(fontData, pixels, spacing);
            fixed (byte* data = fontData)
                fonts.AddMemoryFont((IntPtr)data, fontData.Length);
            Family = fonts.Families[0];
        }
    }

    private static StringFormat TextFormat()
    {
        var format = (StringFormat)StringFormat.GenericTypographic.Clone();
        format.FormatFlags |= StringFormatFlags.NoWrap | StringFormatFlags.MeasureTrailingSpaces;
        return format;
    }

    private GraphicsPath TextPath(Font font, StringFormat format, float lineHeight)
    {
        var path = new GraphicsPath(FillMode.Winding);
        string[] lines = Text.Replace("\r", "").Split('\n');
        Point origin = Points[0];
        for (int index = 0; index < lines.Length; index++)
        {
            if (string.IsNullOrWhiteSpace(lines[index])) continue;
            float y = origin.Y + index * lineHeight;
            path.AddString(lines[index], font.FontFamily, (int)font.Style, FontPixels, new PointF(origin.X, y), format);
        }
        return path;
    }
}

internal static class Geometry
{
    internal static Rectangle Between(Point first, Point second) =>
        Rectangle.FromLTRB(Math.Min(first.X, second.X), Math.Min(first.Y, second.Y),
            Math.Max(first.X, second.X), Math.Max(first.Y, second.Y));

    internal static Point Square(Point start, Point end, Rectangle bounds)
    {
        int dx = end.X - start.X, dy = end.Y - start.Y;
        int size = Math.Max(Math.Abs(dx), Math.Abs(dy));
        size = Math.Min(size, dx < 0 ? start.X - bounds.Left : bounds.Right - start.X);
        size = Math.Min(size, dy < 0 ? start.Y - bounds.Top : bounds.Bottom - start.Y);
        return new Point(start.X + (dx < 0 ? -size : size), start.Y + (dy < 0 ? -size : size));
    }

    internal static Point Clamp(Point point, Rectangle bounds) =>
        new(Math.Clamp(point.X, bounds.Left, bounds.Right), Math.Clamp(point.Y, bounds.Top, bounds.Bottom));

    internal static Point AngleStep(Point start, Point end, Rectangle bounds)
    {
        int dx = end.X - start.X, dy = end.Y - start.Y;
        double angle = Math.Round(Math.Atan2(dy, dx) / (Math.PI / 4)) * (Math.PI / 4);
        int x = (int)Math.Round(Math.Cos(angle)), y = (int)Math.Round(Math.Sin(angle));
        int length = (int)Math.Round((double)(dx * x + dy * y) / (x * x + y * y));
        if (x != 0) length = Math.Min(length, x > 0 ? bounds.Right - start.X : start.X - bounds.Left);
        if (y != 0) length = Math.Min(length, y > 0 ? bounds.Bottom - start.Y : start.Y - bounds.Top);
        return new Point(start.X + x * length, start.Y + y * length);
    }

    internal static Rectangle CenteredCrop(Rectangle display)
    {
        int width = Math.Min(360, display.Width / 2), height = Math.Min(220, display.Height * 2 / 5);
        return new Rectangle(display.X + (display.Width - width) / 2,
            display.Y + (display.Height - height) / 2, width, height);
    }
}
