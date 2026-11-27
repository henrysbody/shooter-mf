namespace Kadr;

internal readonly struct ChalkStroke(float width, uint seed = 0)
{
    private enum Profile { Line, Loop, Shaft, Wing, Pencil }

    private float SampleStep => Math.Clamp(width * .33f, 1, 2.25f);

    internal PointF[][] Line(PointF start, PointF end) => BrushedStroke(Sample([start, end]), Profile.Line);

    private PointF[][] BrushedStroke(IReadOnlyList<PointF> points, Profile profile)
    {
        if (points.Count < 2) return [];
        var distances = new float[points.Count];
        for (int i = 1; i < points.Count; i++)
            distances[i] = distances[i - 1] + Length(points[i].X - points[i - 1].X, points[i].Y - points[i - 1].Y);
        float length = distances[^1];
        float brushWidth = width;
        uint patternSeed = seed;
        (int Segment, PointF Point, PointF Tangent) Position(float distance)
        {
            int segment = 0, upper = points.Count - 1;
            while (upper - segment > 1)
            {
                int middle = (segment + upper) / 2;
                if (distances[middle] <= distance) segment = middle;
                else upper = middle;
            }
            PointF start = points[segment], end = points[segment + 1];
            float dx = end.X - start.X, dy = end.Y - start.Y;
            float span = Length(dx, dy);
            float t = Math.Min(1, (distance - distances[segment]) / span);
            return (segment, distance == length ? end : new PointF(start.X + dx * t, start.Y + dy * t),
                new PointF(dx / span, dy / span));
        }

        (float Trim, PointF[][] Paths) Fray(bool atStart)
        {
            uint random = patternSeed ^ (atStart ? 0xA341316CU : 0xC8013EA4U);
            float Next()
            {
                random = unchecked(random * 1_664_525U + 1_013_904_223U);
                return (random >> 8) / 16_777_216f;
            }
            float span = Math.Min(length * .34f, Math.Max(6, brushWidth * 2.65f) * (.84f + .30f * Next()));
            int count = Math.Clamp((int)MathF.Round(brushWidth) + 3, 5, 13);
            float lane = 1f / count;
            int longest = (int)(Next() * count);
            var paths = new PointF[count][];
            for (int index = 0; index < count; index++)
            {
                float center = (index + .5f) * lane - .5f;
                float offset = center + (Next() - .5f) * lane * .34f;
                float reach = index == longest ? 1 : .50f + .46f * Next();
                float drift = (Next() - .5f) * lane * .4f;
                float shoulder = .32f + .22f * Next(), tip = .075f + .18f * Next();
                PointF Edge(float progress, float spread)
                {
                    float inset = span * (1 - reach * progress);
                    var (_, point, tangent) = Position(atStart ? inset : length - inset);
                    float scale = profile == Profile.Pencil ? PencilWidth(tangent) : 1;
                    float cross = (offset + drift * progress + lane * spread) * brushWidth * scale;
                    return new PointF(point.X - tangent.Y * cross, point.Y + tangent.X * cross);
                }
                PointF[] polygon = [Edge(0, .62f), Edge(.46f, shoulder), Edge(.82f, tip), Edge(1, 0),
                                    Edge(.89f, -tip * .75f), Edge(.53f, -shoulder), Edge(0, -.62f)];
                // The beginning runs backwards. Match the body's winding.
                if (atStart) Array.Reverse(polygon);
                paths[index] = polygon;
            }
            return (span * .53f, paths);
        }

        var start = Fray(atStart: true);
        var finish = profile == Profile.Shaft ? (Trim: 0f, Paths: Array.Empty<PointF[]>()) : Fray(atStart: false);
        var first = Position(start.Trim);
        var last = Position(length - finish.Trim);
        List<PointF> body = [first.Point];
        for (int index = first.Segment + 1; index <= last.Segment; index++)
            if (points[index] != body[^1]) body.Add(points[index]);
        if (last.Point != body[^1]) body.Add(last.Point);
        return [Outline(body, profile), .. start.Paths, .. finish.Paths];
    }

    internal PointF[][] Pencil(IReadOnlyList<Point> vertices) => BrushedStroke(PencilCenterline(vertices), Profile.Pencil);

    internal List<PointF> PencilCenterline(IReadOnlyList<Point> vertices)
    {
        if (vertices.Count < 2) return vertices.Select(point => (PointF)point).ToList();
        PointF start = vertices[0];
        List<PointF> points = [start];
        // Join quadratic curves at midpoints so mouse samples don't leave corners.
        for (int index = 1; index < vertices.Count - 1; index++)
        {
            PointF control = vertices[index], next = vertices[index + 1];
            var end = new PointF((control.X + next.X) / 2, (control.Y + next.Y) / 2);
            float length = Length(control.X - start.X, control.Y - start.Y) + Length(end.X - control.X, end.Y - control.Y);
            int count = Math.Max(1, (int)MathF.Ceiling(length / SampleStep));
            for (int sample = 1; sample <= count; sample++)
            {
                float t = (float)sample / count, u = 1 - t;
                var point = new PointF(u * u * start.X + 2 * u * t * control.X + t * t * end.X,
                    u * u * start.Y + 2 * u * t * control.Y + t * t * end.Y);
                if (point != points[^1]) points.Add(point);
            }
            start = end;
        }
        points.AddRange(Sample([start, vertices[^1]]).Skip(1));
        return points;
    }

    internal PointF[][] Arrow(PointF start, PointF tip, PointF left, PointF right)
    {
        float separation = Length(left.X - right.X, left.Y - right.Y);
        var outward = new PointF((left.X - right.X) / separation, (left.Y - right.Y) / separation);
        var wingBrush = new ChalkStroke(width * .73f);
        float bend = Math.Min(width * .35f, separation * .14f);
        return [.. BrushedStroke(Sample([start, tip]), Profile.Shaft),
                wingBrush.Outline(Wing(left, tip, outward, bend), Profile.Wing),
                wingBrush.Outline(Wing(right, tip, new PointF(-outward.X, -outward.Y), bend), Profile.Wing)];
    }

    private PointF[] Wing(PointF start, PointF tip, PointF outward, float bend)
    {
        float dx = tip.X - start.X, dy = tip.Y - start.Y;
        float length = Length(dx, dy);
        int count = Math.Max(6, (int)MathF.Ceiling(length / SampleStep));
        var points = new PointF[count + 1];
        for (int index = 0; index < count; index++)
        {
            float t = (float)index / count;
            // Pull the middle inward so the free end flares away from the shaft.
            float inset = 4 * bend * t * (1 - t) * (1 - t);
            points[index] = new PointF(start.X + dx * t - outward.X * inset, start.Y + dy * t - outward.Y * inset);
        }
        points[count] = tip;
        return points;
    }

    internal PointF[] Rectangle(RectangleF rect)
    {
        float seam = rect.Left + rect.Width / 2;
        float overlap = Math.Min(width * 1.35f, rect.Width * .15f);
        return DiagonalLoop(Sample([
            new PointF(seam, rect.Top), new PointF(rect.Right, rect.Top),
            new PointF(rect.Right, rect.Bottom), new PointF(rect.Left, rect.Bottom),
            new PointF(rect.Left, rect.Top), new PointF(seam + overlap, rect.Top)
        ]), rect, contrast: .14f);
    }

    internal PointF[] Oval(RectangleF rect)
    {
        float rx = rect.Width / 2, ry = rect.Height / 2;
        float startAngle = MathF.PI * .43f;
        float speed = Length(rx * MathF.Sin(startAngle), ry * MathF.Cos(startAngle));
        float overlap = Math.Min(.24f, width * 1.35f / speed);
        float circumference = MathF.PI * (3 * (rx + ry) - MathF.Sqrt((3 * rx + ry) * (rx + 3 * ry)));
        int count = Math.Max(64, (int)MathF.Ceiling((circumference + overlap * speed) / SampleStep));
        float angleStep = (2 * MathF.PI + overlap) / count;
        var points = new List<PointF>(count + 1);
        for (int index = 0; index <= count; index++)
        {
            float angle = startAngle + index * angleStep;
            var point = new PointF(rect.Left + rx + rx * MathF.Cos(angle),
                rect.Top + ry - ry * MathF.Sin(angle));
            if (points.Count == 0 || point != points[^1]) points.Add(point);
        }
        return DiagonalLoop(points, rect, contrast: .28f);
    }

    private PointF[] DiagonalLoop(IReadOnlyList<PointF> points, RectangleF rect, float contrast) =>
        Outline(points, Profile.Loop, point =>
        {
            float x = (point.X - (rect.Left + rect.Width / 2)) / (rect.Width / 2);
            float y = (point.Y - (rect.Top + rect.Height / 2)) / (rect.Height / 2);
            return 1 + contrast * x * y;
        });

    private List<PointF> Sample(PointF[] vertices)
    {
        List<PointF> points = [vertices[0]];
        for (int index = 1; index < vertices.Length; index++)
        {
            PointF start = vertices[index - 1], end = vertices[index];
            float dx = end.X - start.X, dy = end.Y - start.Y;
            int count = Math.Max(1, (int)MathF.Ceiling(Length(dx, dy) / SampleStep));
            for (int sample = 1; sample < count; sample++)
            {
                float fraction = (float)sample / count;
                points.Add(new PointF(start.X + dx * fraction, start.Y + dy * fraction));
            }
            if (end != start) points.Add(end);
        }
        return points;
    }

    private PointF[] Outline(IReadOnlyList<PointF> points, Profile profile, Func<PointF, float>? widthScale = null)
    {
        if (points.Count < 2) return [];
        var distances = new float[points.Count];
        var tangents = new PointF[points.Count - 1];
        for (int index = 1; index < points.Count; index++)
        {
            float dx = points[index].X - points[index - 1].X, dy = points[index].Y - points[index - 1].Y;
            float step = Length(dx, dy);
            distances[index] = distances[index - 1] + step;
            tangents[index - 1] = new PointF(dx / step, dy / step);
        }
        float length = distances[^1];
        bool closesLoop = profile == Profile.Loop;
        bool broadStart = profile is Profile.Line or Profile.Shaft;
        bool pointed = profile is Profile.Shaft or Profile.Wing;
        bool freehand = profile == Profile.Pencil;
        bool brushed = broadStart || freehand;
        float trimDepth = Math.Min(.25f, length * .12f / width);
        float lead = Math.Min(length * .31f, Math.Max(6, width * (broadStart ? 1.75f : closesLoop ? 1.9f : 2.5f)));
        float finish = Math.Min(length * .34f, closesLoop ? Math.Max(8, width * 2.5f) : Math.Max(6, width * 1.7f));
        float firstPressure = brushed ? .90f : closesLoop ? .64f : .60f;
        float lastPressure = closesLoop ? .46f : .90f;
        float tipSlope = profile == Profile.Wing ? .145f : .30f;
        var left = new PointF[points.Count];
        var right = new PointF[points.Count];
        for (int index = 0; index < points.Count; index++)
        {
            PointF before = tangents[Math.Max(0, index - 1)], after = tangents[Math.Min(index, tangents.Length - 1)];
            float dx = before.X + after.X, dy = before.Y + after.Y;
            float bisector = Length(dx, dy);
            float divisor = Math.Max(bisector * bisector / 2, bisector / 1.42f);
            float nx = divisor > 0 ? -dy / divisor : -after.Y;
            float ny = divisor > 0 ? dx / divisor : after.X;
            float distance = distances[index];
            float ramp = Ease(distance, lead);
            float entry = firstPressure + (1 - firstPressure) * ramp + (broadStart ? .24f * MathF.Sin(MathF.PI * ramp) : 0);
            float remaining = length - distance;
            float exit = pointed ? 1 : lastPressure + (1 - lastPressure) * Ease(remaining, finish);
            PointF point = points[index];
            PointF tangent = bisector > 0 ? new PointF(dx / bisector, dy / bisector) : after;
            float nib = freehand ? PencilWidth(tangent) : 1;
            float pressureRadius = width / 2 * entry * exit * (widthScale?.Invoke(point) ?? 1) * nib;
            float radius = pointed ? Math.Min(pressureRadius, remaining * tipSlope) : pressureRadius;
            float grain = freehand ? Math.Min(.26f, radius * .09f) : Math.Min(.18f, radius * .065f);
            float leftRadius = radius + grain * MathF.Sin(distance * 2.7f + .4f);
            float rightRadius = radius + grain * MathF.Sin(distance * 3.2f + 1.8f);
            left[index] = new PointF(point.X + nx * leftRadius, point.Y + ny * leftRadius);
            right[index] = new PointF(point.X - nx * rightRadius, point.Y - ny * rightRadius);
        }
        float depth = brushed ? trimDepth : .86f;
        var startCap = Cap(right[0], left[0], new PointF(-tangents[0].X, -tangents[0].Y), depth);
        return pointed
            ? [.. left, .. right.SkipLast(1).Reverse(), .. startCap]
            : [.. left, .. Cap(left[^1], right[^1], tangents[^1], depth),
               .. right.Reverse(), .. startCap];
    }

    private static float Ease(float distance, float span)
    {
        float fraction = Math.Min(1, distance / span);
        return fraction * fraction * (3 - 2 * fraction);
    }

    // In Windows screen coordinates, ↗ has opposite x and y signs.
    private static float PencilWidth(PointF tangent) => 1 - .44f * tangent.X * tangent.Y;

    private static IEnumerable<PointF> Cap(PointF a, PointF b, PointF outward, float depth = .86f)
    {
        float rx = (a.X - b.X) / 2, ry = (a.Y - b.Y) / 2;
        float x = (a.X + b.X) / 2, y = (a.Y + b.Y) / 2;
        float radius = Length(rx, ry) * depth;
        for (int index = 1; index < 8; index++)
        {
            float angle = index * MathF.PI / 8;
            float arc = MathF.Sin(angle) * radius;
            yield return new PointF(x + rx * MathF.Cos(angle) + outward.X * arc,
                y + ry * MathF.Cos(angle) + outward.Y * arc);
        }
    }

    private static float Length(float dx, float dy) => MathF.Sqrt(dx * dx + dy * dy);
}
