using static System.Buffers.Binary.BinaryPrimitives;

namespace Kadr;

internal static class FontTracking
{
    // Apply spacing in design units so native shaping, the caret and the exported path agree.
    internal static void Adjust(Span<byte> font, float pixelsPerEm, int spacingPixels)
    {
        Table head = FindTable(font, "head"u8);
        Table horizontal = FindTable(font, "hhea"u8);
        Table metrics = FindTable(font, "hmtx"u8);
        int unitsPerEm = ReadUInt16BigEndian(font[(head.Offset + 18)..]);
        int adjustmentUnits = (int)Math.Round(spacingPixels * unitsPerEm / pixelsPerEm);
        int count = ReadUInt16BigEndian(font[(horizontal.Offset + 34)..]);
        ushort widest = 0;
        for (int glyph = 0; glyph < count; glyph++)
        {
            Span<byte> advance = font[(metrics.Offset + glyph * 4)..];
            ushort width = ReadUInt16BigEndian(advance);
            // Glyph zero is the missing-glyph placeholder. Zero-advance marks also stay in place.
            if (glyph != 0 && width > 0)
            {
                width = (ushort)Math.Max(1, width + adjustmentUnits);
                WriteUInt16BigEndian(advance, width);
            }
            widest = Math.Max(widest, width);
        }
        WriteUInt16BigEndian(font[(horizontal.Offset + 10)..], widest);
        Span<byte> minimumRightBearing = font[(horizontal.Offset + 14)..];
        int bearing = ReadInt16BigEndian(minimumRightBearing) + adjustmentUnits;
        WriteInt16BigEndian(minimumRightBearing, (short)Math.Max(short.MinValue, bearing));

        WriteUInt32BigEndian(font[(horizontal.Entry + 4)..], Checksum(font.Slice(horizontal.Offset, horizontal.Length)));
        WriteUInt32BigEndian(font[(metrics.Entry + 4)..], Checksum(font.Slice(metrics.Offset, metrics.Length)));
        Span<byte> adjustment = font.Slice(head.Offset + 8, 4);
        adjustment.Clear();
        WriteUInt32BigEndian(adjustment, unchecked(0xB1B0AFBAu - Checksum(font)));
    }

    private readonly record struct Table(int Entry, int Offset, int Length);

    private static Table FindTable(ReadOnlySpan<byte> font, ReadOnlySpan<byte> tag)
    {
        int tables = ReadUInt16BigEndian(font[4..]);
        for (int index = 0; index < tables; index++)
        {
            int entry = 12 + index * 16;
            if (font.Slice(entry, 4).SequenceEqual(tag))
            {
                int offset = checked((int)ReadUInt32BigEndian(font[(entry + 8)..]));
                int length = checked((int)ReadUInt32BigEndian(font[(entry + 12)..]));
                return new Table(entry, offset, length);
            }
        }
        throw new InvalidDataException("Missing table in the embedded annotation font.");
    }

    private static uint Checksum(ReadOnlySpan<byte> data)
    {
        uint total = 0;
        int offset = 0;
        unchecked
        {
            for (; offset <= data.Length - 4; offset += 4)
                total += ReadUInt32BigEndian(data[offset..]);
            uint tail = 0;
            for (int index = 0; offset + index < data.Length; index++)
                tail |= (uint)data[offset + index] << (24 - index * 8);
            return total + tail;
        }
    }
}
