using System.Buffers;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;

namespace Kadr;

internal static class AnnotationShadow
{
    private const int Offset = 2;
    private const int DirectionalRadius = 2;
    private const byte DirectionalOpacity = 74;

    internal static void Draw(Graphics graphics, GraphicsPath silhouette, int ambientRadius, byte ambient)
    {
        int padding = Math.Max(ambientRadius, DirectionalRadius) * ShadowBlur.Passes + Offset + 1;
        RectangleF shadowBounds = RectangleF.Inflate(silhouette.GetBounds(), padding, padding);
        Rectangle area = PixelBounds(RectangleF.Intersect(shadowBounds, graphics.VisibleClipBounds));
        if (area.Width <= 0 || area.Height <= 0) return;

        // Keep the silhouette outside the crop in the mask so its shadow can reach the crop edge.
        Rectangle raster = Rectangle.Inflate(area, padding, padding);
        using var mask = new Bitmap(raster.Width, raster.Height, PixelFormat.Format32bppPArgb);
        using (Graphics painter = Graphics.FromImage(mask))
        {
            painter.PageUnit = GraphicsUnit.Pixel;
            painter.SmoothingMode = graphics.SmoothingMode;
            painter.PixelOffsetMode = graphics.PixelOffsetMode;
            painter.TranslateTransform(-raster.X, -raster.Y);
            painter.FillPath(Brushes.White, silhouette);
        }
        BlurMask(mask, ambientRadius, ambient);
        var source = new Rectangle(padding, padding, area.Width, area.Height);
        graphics.DrawImage(mask, area, source, GraphicsUnit.Pixel);
    }

    private static Rectangle PixelBounds(RectangleF bounds) => Rectangle.FromLTRB(
        (int)MathF.Floor(bounds.Left), (int)MathF.Floor(bounds.Top),
        (int)MathF.Ceiling(bounds.Right), (int)MathF.Ceiling(bounds.Bottom));

    private static unsafe void BlurMask(Bitmap mask, int ambientRadius, byte ambient)
    {
        int width = mask.Width, height = mask.Height;
        int length = checked(width * height);
        byte[] buffer = ArrayPool<byte>.Shared.Rent(length);
        byte[]? directionalBuffer = null;
        try
        {
            if (ambientRadius != DirectionalRadius) directionalBuffer = ArrayPool<byte>.Shared.Rent(length);
            var bounds = new Rectangle(0, 0, width, height);
            BitmapData bits = mask.LockBits(bounds, ImageLockMode.ReadWrite, PixelFormat.Format32bppPArgb);
            try
            {
                Span<byte> coverage = buffer.AsSpan(0, length);
                byte* first = (byte*)bits.Scan0;
                for (int y = 0; y < height; y++)
                {
                    byte* row = first + y * bits.Stride;
                    for (int x = 0; x < width; x++) coverage[y * width + x] = row[4 * x + 3];
                }

                Span<byte> directional = coverage;
                if (directionalBuffer is not null)
                {
                    directional = directionalBuffer.AsSpan(0, length);
                    coverage.CopyTo(directional);
                    ShadowBlur.Apply(directional, width, height, DirectionalRadius);
                }
                ShadowBlur.Apply(coverage, width, height, ambientRadius);
                for (int y = 0; y < height; y++)
                {
                    var row = (uint*)(first + y * bits.Stride);
                    int index = y * width;
                    for (int x = 0; x < width; x++)
                    {
                        byte shifted = x >= Offset && y >= Offset ? directional[index + x - Offset * (width + 1)] : (byte)0;
                        byte alpha = ShadowBlur.Composite(coverage[index + x], shifted, ambient, DirectionalOpacity);
                        row[x] = (uint)alpha << 24;
                    }
                }
            }
            finally
            {
                mask.UnlockBits(bits);
            }
        }
        finally
        {
            if (directionalBuffer is not null) ArrayPool<byte>.Shared.Return(directionalBuffer);
            ArrayPool<byte>.Shared.Return(buffer);
        }
    }
}
