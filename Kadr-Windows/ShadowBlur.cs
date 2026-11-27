using System.Buffers;

namespace Kadr;

internal static class ShadowBlur
{
    // Three box passes give a smooth Gaussian-like falloff and have a finite edge.
    internal const int Passes = 3;

    internal static void Apply(Span<byte> coverage, int width, int height, int radius)
    {
        byte[] buffer = ArrayPool<byte>.Shared.Rent(coverage.Length);
        int[] columns = ArrayPool<int>.Shared.Rent(width);
        try
        {
            Span<byte> horizontal = buffer.AsSpan(0, coverage.Length);
            Span<int> totals = columns.AsSpan(0, width);
            int window = 2 * radius + 1;
            Span<byte> average = stackalloc byte[window * 255 + 1];
            for (int i = 0; i < average.Length; i++) average[i] = (byte)((i + radius) / window);

            for (int pass = 0; pass < Passes; pass++)
            {
                for (int row = 0; row < height; row++)
                {
                    int offset = row * width;
                    int sum = 0;
                    for (int x = 0; x < Math.Min(width, radius + 1); x++) sum += coverage[offset + x];
                    for (int x = 0; x < width; x++)
                    {
                        horizontal[offset + x] = average[sum];
                        if (x >= radius) sum -= coverage[offset + x - radius];
                        if (x + radius + 1 < width) sum += coverage[offset + x + radius + 1];
                    }
                }

                totals.Clear();
                for (int row = 0; row < Math.Min(height, radius + 1); row++)
                {
                    int offset = row * width;
                    for (int x = 0; x < width; x++) totals[x] += horizontal[offset + x];
                }
                for (int row = 0; row < height; row++)
                {
                    int offset = row * width;
                    for (int x = 0; x < width; x++) coverage[offset + x] = average[totals[x]];
                    if (row >= radius)
                    {
                        int leaving = (row - radius) * width;
                        for (int x = 0; x < width; x++) totals[x] -= horizontal[leaving + x];
                    }
                    if (row + radius + 1 < height)
                    {
                        int entering = (row + radius + 1) * width;
                        for (int x = 0; x < width; x++) totals[x] += horizontal[entering + x];
                    }
                }
            }
        }
        finally
        {
            ArrayPool<int>.Shared.Return(columns);
            ArrayPool<byte>.Shared.Return(buffer);
        }
    }

    internal static byte Composite(byte centered, byte offset, byte ambient, byte directional)
    {
        int first = (centered * ambient + 127) / 255;
        int second = (offset * directional + 127) / 255;
        return (byte)(first + (second * (255 - first) + 127) / 255);
    }
}
