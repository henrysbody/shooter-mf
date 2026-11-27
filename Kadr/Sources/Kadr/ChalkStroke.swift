import CoreGraphics

struct ChalkStroke {
    private enum Profile { case line, loop, shaft, wing, pencil }

    let width: CGFloat
    let seed: UInt32

    init(width: CGFloat, seed: UInt32 = 0) {
        self.width = width
        self.seed = seed
    }

    private var sampleStep: CGFloat { min(2.25, max(1, width * 0.33)) }

    func line(from start: CGPoint, to end: CGPoint) -> [[CGPoint]] {
        brushedStroke(sample([start, end]), profile: .line)
    }

    private func brushedStroke(_ points: [CGPoint], profile: Profile) -> [[CGPoint]] {
        guard points.count > 1 else { return [] }
        var distances: [CGFloat] = [0]
        for (start, end) in zip(points, points.dropFirst()) {
            distances.append(distances.last! + hypot(end.x - start.x, end.y - start.y))
        }
        let length = distances.last!
        func position(at distance: CGFloat) -> (segment: Int, point: CGPoint, tangent: CGVector) {
            var segment = 0
            var upper = points.count - 1
            while upper - segment > 1 {
                let middle = (segment + upper) / 2
                if distances[middle] <= distance { segment = middle }
                else { upper = middle }
            }
            let start = points[segment], end = points[segment + 1]
            let span = hypot(end.x - start.x, end.y - start.y)
            let t = min(1, (distance - distances[segment]) / span)
            return (segment,
                    distance == length ? end : CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t),
                    CGVector(dx: (end.x - start.x) / span, dy: (end.y - start.y) / span))
        }

        func fray(atStart: Bool) -> (trim: CGFloat, paths: [[CGPoint]]) {
            var random = seed ^ (atStart ? 0xA341316C : 0xC8013EA4)
            func next() -> CGFloat {
                random = random &* 1_664_525 &+ 1_013_904_223
                return CGFloat(random >> 8) / 16_777_216
            }
            let span = min(length * 0.34, max(6, width * 2.65) * (0.84 + 0.30 * next()))
            let count = min(13, max(5, Int(width.rounded()) + 3))
            let lane = 1 / CGFloat(count)
            let longest = Int(next() * CGFloat(count))
            let paths = (0..<count).map { index -> [CGPoint] in
                let center = (CGFloat(index) + 0.5) * lane - 0.5
                let offset = center + (next() - 0.5) * lane * 0.34
                let reach = index == longest ? CGFloat(1) : 0.50 + 0.46 * next()
                let drift = (next() - 0.5) * lane * 0.40
                let shoulder = 0.32 + 0.22 * next(), tip = 0.075 + 0.18 * next()
                func edge(_ progress: CGFloat, spread: CGFloat) -> CGPoint {
                    let inset = span * (1 - reach * progress)
                    let (_, point, tangent) = position(at: atStart ? inset : length - inset)
                    let scale = profile == .pencil ? pencilWidth(along: tangent) : 1
                    let cross = (offset + drift * progress + lane * spread) * width * scale
                    return CGPoint(x: point.x - tangent.dy * cross, y: point.y + tangent.dx * cross)
                }
                let polygon = [edge(0, spread: 0.62), edge(0.46, spread: shoulder),
                               edge(0.82, spread: tip), edge(1, spread: 0),
                               edge(0.89, spread: -tip * 0.75), edge(0.53, spread: -shoulder),
                               edge(0, spread: -0.62)]
                // The beginning runs backwards. Keep the same winding as the body so the overlap stays filled.
                return atStart ? Array(polygon.reversed()) : polygon
            }
            return (span * 0.53, paths)
        }

        let start = fray(atStart: true)
        let finish = profile == .shaft ? (trim: CGFloat(0), paths: [[CGPoint]]()) : fray(atStart: false)
        let first = position(at: start.trim), last = position(at: length - finish.trim)
        var body = [first.point]
        for point in points[(first.segment + 1)..<(last.segment + 1)] where point != body.last {
            body.append(point)
        }
        if last.point != body.last { body.append(last.point) }
        return [outline(body, profile: profile)] + start.paths + finish.paths
    }

    func pencil(_ vertices: [CGPoint]) -> [[CGPoint]] {
        brushedStroke(pencilCenterline(vertices), profile: .pencil)
    }

    func pencilCenterline(_ vertices: [CGPoint]) -> [CGPoint] {
        guard let first = vertices.first, let last = vertices.last, vertices.count > 1 else { return vertices }
        var points = [first]
        var start = first
        // Join quadratic curves at midpoints so mouse samples don't leave corners.
        for index in 1..<(vertices.count - 1) {
            let control = vertices[index], next = vertices[index + 1]
            let end = CGPoint(x: (control.x + next.x) / 2, y: (control.y + next.y) / 2)
            let length = hypot(control.x - start.x, control.y - start.y) + hypot(end.x - control.x, end.y - control.y)
            let count = max(1, Int(ceil(length / sampleStep)))
            for sample in 1...count {
                let t = CGFloat(sample) / CGFloat(count), u = 1 - t
                let point = CGPoint(x: u * u * start.x + 2 * u * t * control.x + t * t * end.x,
                                    y: u * u * start.y + 2 * u * t * control.y + t * t * end.y)
                if point != points.last { points.append(point) }
            }
            start = end
        }
        points.append(contentsOf: sample([start, last]).dropFirst())
        return points
    }

    func arrow(from start: CGPoint, to tip: CGPoint, left: CGPoint, right: CGPoint) -> [[CGPoint]] {
        let separation = hypot(left.x - right.x, left.y - right.y)
        let outward = CGVector(dx: (left.x - right.x) / separation, dy: (left.y - right.y) / separation)
        let wingBrush = ChalkStroke(width: width * 0.73)
        let bend = min(width * 0.35, separation * 0.14)
        return brushedStroke(sample([start, tip]), profile: .shaft) + [
                wingBrush.outline(wing(from: left, to: tip, outward: outward, bend: bend), profile: .wing),
                wingBrush.outline(wing(from: right, to: tip,
                                       outward: CGVector(dx: -outward.dx, dy: -outward.dy), bend: bend), profile: .wing)]
    }

    private func wing(from start: CGPoint, to tip: CGPoint, outward: CGVector, bend: CGFloat) -> [CGPoint] {
        let dx = tip.x - start.x, dy = tip.y - start.y
        let length = hypot(dx, dy)
        let count = max(6, Int(ceil(length / sampleStep)))
        return (0...count).map { index in
            if index == count { return tip }
            let t = CGFloat(index) / CGFloat(count)
            // Pull the middle inward so the free end flares away from the shaft.
            let inset = 4 * bend * t * (1 - t) * (1 - t)
            return CGPoint(x: start.x + dx * t - outward.dx * inset,
                           y: start.y + dy * t - outward.dy * inset)
        }
    }

    func rectangle(_ rect: CGRect) -> [CGPoint] {
        let seam = rect.midX
        let overlap = min(width * 1.35, rect.width * 0.15)
        return diagonalLoop(sample([
            CGPoint(x: seam, y: rect.maxY),
            CGPoint(x: rect.maxX, y: rect.maxY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.minX, y: rect.maxY),
            CGPoint(x: seam + overlap, y: rect.maxY)
        ]), in: rect, contrast: 0.14)
    }

    func oval(_ rect: CGRect) -> [CGPoint] {
        let rx = rect.width / 2, ry = rect.height / 2
        let startAngle = CGFloat.pi * 0.43
        let speed = hypot(rx * sin(startAngle), ry * cos(startAngle))
        let overlap = min(0.24, width * 1.35 / speed)
        let circumference = CGFloat.pi * (3 * (rx + ry) - sqrt((3 * rx + ry) * (rx + 3 * ry)))
        let count = max(64, Int(ceil((circumference + overlap * speed) / sampleStep)))
        let angleStep = (2 * .pi + overlap) / CGFloat(count)
        return diagonalLoop((0...count).map { index in
            let angle = startAngle + CGFloat(index) * angleStep
            return CGPoint(x: rect.midX + rx * cos(angle), y: rect.midY + ry * sin(angle))
        }, in: rect, contrast: 0.28)
    }

    private func diagonalLoop(_ points: [CGPoint], in rect: CGRect, contrast: CGFloat) -> [CGPoint] {
        outline(points, profile: .loop) { point in
            let x = (point.x - rect.midX) / (rect.width / 2)
            let y = (point.y - rect.midY) / (rect.height / 2)
            return 1 - contrast * x * y
        }
    }

    private func sample(_ vertices: [CGPoint]) -> [CGPoint] {
        var points = [vertices[0]]
        for (start, end) in zip(vertices, vertices.dropFirst()) {
            let dx = end.x - start.x, dy = end.y - start.y
            let count = max(1, Int(ceil(hypot(dx, dy) / sampleStep)))
            for index in 1..<count {
                let fraction = CGFloat(index) / CGFloat(count)
                points.append(CGPoint(x: start.x + dx * fraction, y: start.y + dy * fraction))
            }
            if end != start { points.append(end) }
        }
        return points
    }

    private func outline(_ points: [CGPoint], profile: Profile, widthScale: (CGPoint) -> CGFloat = { _ in 1 }) -> [CGPoint] {
        guard points.count >= 2 else { return [] }
        var distances: [CGFloat] = [0]
        var tangents: [CGVector] = []
        for (start, end) in zip(points, points.dropFirst()) {
            let dx = end.x - start.x, dy = end.y - start.y
            let length = hypot(dx, dy)
            distances.append(distances.last! + length)
            tangents.append(CGVector(dx: dx / length, dy: dy / length))
        }
        let length = distances.last!
        let closesLoop = profile == .loop
        let broadStart = profile == .line || profile == .shaft
        let pointed = profile == .shaft || profile == .wing
        let freehand = profile == .pencil
        let brushed = broadStart || freehand
        let trimDepth = min(0.25, length * 0.12 / width)
        let lead = min(length * 0.31, max(6, width * (broadStart ? 1.75 : closesLoop ? 1.9 : 2.5)))
        let finish = min(length * 0.34, closesLoop ? max(8, width * 2.5) : max(6, width * 1.7))
        let firstPressure: CGFloat = brushed ? 0.90 : closesLoop ? 0.64 : 0.60
        let lastPressure: CGFloat = closesLoop ? 0.46 : 0.90
        let tipSlope: CGFloat = profile == .wing ? 0.145 : 0.30
        func ease(_ distance: CGFloat, over span: CGFloat) -> CGFloat {
            let t = min(1, distance / span)
            return t * t * (3 - 2 * t)
        }

        var left: [CGPoint] = [], right: [CGPoint] = []
        for (index, point) in points.enumerated() {
            let before = tangents[max(0, index - 1)]
            let after = tangents[min(index, tangents.count - 1)]
            let dx = before.dx + after.dx, dy = before.dy + after.dy
            let bisector = hypot(dx, dy)
            // Keep square corners and limit the extension at acute points.
            let divisor = max(bisector * bisector / 2, bisector / 1.42)
            let nx = divisor > 0 ? -dy / divisor : -after.dy
            let ny = divisor > 0 ? dx / divisor : after.dx
            let distance = distances[index]
            let ramp = ease(distance, over: lead)
            let entry = firstPressure + (1 - firstPressure) * ramp + (broadStart ? 0.24 * sin(.pi * ramp) : 0)
            let remaining = length - distance
            let exit = pointed ? 1 : lastPressure + (1 - lastPressure) * ease(remaining, over: finish)
            let tangent = bisector > 0 ? CGVector(dx: dx / bisector, dy: dy / bisector) : after
            let nib = freehand ? pencilWidth(along: tangent) : 1
            let pressureRadius = width / 2 * entry * exit * widthScale(point) * nib
            let radius = pointed ? min(pressureRadius, remaining * tipSlope) : pressureRadius
            let grain = freehand ? min(0.26, radius * 0.09) : min(0.18, radius * 0.065)
            let leftRadius = radius + grain * sin(distance * 2.7 + 0.4)
            let rightRadius = radius + grain * sin(distance * 3.2 + 1.8)
            left.append(CGPoint(x: point.x + nx * leftRadius, y: point.y + ny * leftRadius))
            right.append(CGPoint(x: point.x - nx * rightRadius, y: point.y - ny * rightRadius))
        }

        let first = tangents[0]
        var polygon = left
        if pointed {
            polygon.append(contentsOf: right.dropLast().reversed())
        } else {
            let depth = brushed ? trimDepth : 0.86
            polygon.append(contentsOf: cap(from: left.last!, to: right.last!, outward: tangents.last!, depth: depth))
            polygon.append(contentsOf: right.reversed())
        }
        polygon.append(contentsOf: cap(from: right[0], to: left[0],
                                       outward: CGVector(dx: -first.dx, dy: -first.dy),
                                       depth: brushed ? trimDepth : 0.86))
        return polygon
    }

    private func pencilWidth(along tangent: CGVector) -> CGFloat {
        // The broad edge of the pencil is strongest along the ↗ axis.
        1 + 0.44 * tangent.dx * tangent.dy
    }

    private func cap(from a: CGPoint, to b: CGPoint, outward: CGVector, depth: CGFloat = 0.86) -> [CGPoint] {
        let rx = (a.x - b.x) / 2, ry = (a.y - b.y) / 2
        let center = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        let radius = hypot(rx, ry) * depth
        return (1..<8).map { index in
            let angle = CGFloat(index) * .pi / 8
            let arc = sin(angle) * radius
            return CGPoint(x: center.x + rx * cos(angle) + outward.dx * arc,
                           y: center.y + ry * cos(angle) + outward.dy * arc)
        }
    }
}
