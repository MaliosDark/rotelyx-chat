import SwiftUI
import WatchKit

/// A message going up in smoke, on a wrist.
///
/// # This is `shaders/burn.frag`, arithmetic for arithmetic
///
/// The phone burns a message with a fragment shader. The watch cannot run it:
/// `ShaderLibrary` and `colorEffect` are unavailable on watchOS, which the
/// compiler will tell you plainly, so the same field is evaluated here on the
/// processor and drawn with `Canvas`.
///
/// Ported rather than reinvented, and the difference matters. An effect written
/// afresh for the watch is a second fire, and two fires in one application is
/// two things to keep in step and one of them always drifting. Every constant
/// below is the constant in the shader: the two octaves that decide where the
/// front is, the high frequency term at a tenth of the amplitude that frays it,
/// the four heat bands weighted towards char, the twenty four procedural
/// sparks. Change one there and change it here.
///
/// # What is different, and why it has to be
///
/// A shader answers "what colour is this pixel"; `Canvas` answers "what shapes
/// are on this screen". So the tear is solved for rather than tested against:
/// for each column the field is inverted to find the row where it crosses the
/// threshold, and the heat is drawn as strips lying along that curve instead of
/// as a test on every pixel. On a screen two hundred points wide the result is
/// the same picture and the arithmetic is a few thousand operations.
///
/// # Why it is felt as well as seen
///
/// This is the one event in the application where something is destroyed, and
/// on a wrist it can happen while nobody is looking. The haptic is what makes
/// it real.
struct Burning<Content: View>: View {
    let content: Content
    let onGone: () -> Void

    init(onGone: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.onGone = onGone
        self.content = content()
    }

    /// Moves per message, so no two burn identically. The shader's `uSeed`.
    private let seed = CGFloat.random(in: 0...10)

    /// When the fire caught. Nil until the view has settled, which keeps the
    /// first frame out of the same transaction as the view's own insertion:
    /// an earlier version began in `onAppear` and was drawn already finished.
    @State private var began: Date?

    var body: some View {
        // Every frame, driven by the clock.
        //
        // `withAnimation` was how this ran once, and it is why the fire was
        // invisible: it sets a value and lets SwiftUI interpolate whatever is
        // animatable between the two ends. A height interpolates, so the
        // message really was consumed, but anything written as a condition is
        // evaluated at the final value and nowhere in between, and at the end
        // of a burn every ember is out. Eight seconds of fire drawn at zero.
        TimelineView(.animation(paused: began == nil)) { tick in
            let progress = progress(at: tick.date)

            content
                .mask { Canvas { c, size in tear(c, size, progress) } }
                .overlay { Canvas { c, size in heat(c, size, progress) } }
                .overlay {
                    // Room above and to the sides, because the sparks leave the
                    // message and cross the conversation the way real ones
                    // would. The shader is handed a bigger canvas for exactly
                    // this and told where the bubble sits inside it.
                    GeometryReader { box in
                        Canvas { c, size in
                            embers(c, size, box.size, progress)
                        }
                        .frame(width: box.size.width + 40,
                               height: box.size.height + emberRoom)
                        .offset(x: -20, y: -emberRoom)
                        .allowsHitTesting(false)
                    }
                }
        }
        .task { await start() }
    }

    private var emberRoom: CGFloat { 70 }

    // MARK: - The field

    /// Where the tear is, for a given column.
    ///
    /// The shader asks "is this pixel past the front"; here the question is
    /// turned around and the row is solved for. `front` in the shader is the
    /// row itself, so the equation is `y + wander(x, y) + fray(x, y) =
    /// threshold`, and two rounds of substitution settle it: the two noise
    /// terms move the answer by less than a third of the height between them,
    /// so there is nothing for a third round to find.
    private func tearRow(atColumn ux: CGFloat, aspect: CGFloat, threshold: CGFloat) -> CGFloat {
        var uy = threshold
        for _ in 0..<2 {
            let p = CGPoint(x: ux * aspect, y: uy)
            let wander = (shape(p, 3.1, seed * 7) - 0.5) * 0.30
            let fray = (shape(p, 14.0, seed * 3) - 0.5) * 0.05
            uy = threshold - wander - fray
        }
        return uy
    }

    /// Rises a little past one so the last of the char has somewhere to finish.
    private func threshold(_ progress: CGFloat) -> CGFloat {
        progress * 1.30 - 0.14
    }

    /// The tear as a path, and everything below it.
    private func curve(_ size: CGSize, _ progress: CGFloat) -> [CGPoint] {
        let aspect = size.width / max(size.height, 1)
        let t = threshold(progress)
        let step: CGFloat = 3

        var points: [CGPoint] = []
        var x: CGFloat = 0
        while x <= size.width {
            let uy = tearRow(atColumn: x / max(size.width, 1), aspect: aspect, threshold: t)
            points.append(CGPoint(x: x, y: uy * size.height))
            x += step
        }
        return points
    }

    // MARK: - The three passes

    /// The mask that eats the message. The shader's `uMode` nought.
    private func tear(_ c: GraphicsContext, _ size: CGSize, _ progress: CGFloat) {
        var path = Path()
        let points = curve(size, progress)
        guard let first = points.first else { return }

        path.move(to: CGPoint(x: 0, y: size.height))
        path.addLine(to: first)
        for p in points.dropFirst() { path.addLine(to: p) }
        path.addLine(to: CGPoint(x: size.width, y: size.height))
        path.closeSubpath()

        c.fill(path, with: .color(.white))
    }

    /// The heated band on the tear, and nothing outside it. `uMode` one.
    ///
    /// Drawn as strips lying along the curve rather than as a test per pixel,
    /// with the shader's own bands: most of the strip is char and only the last
    /// sliver is bright, which is the proportion a real edge has. Without the
    /// dark band the flame looks like a coloured filter passing over the text.
    private func heat(_ c: GraphicsContext, _ size: CGSize, _ progress: CGFloat) {
        let points = curve(size, progress)
        guard points.count > 1 else { return }

        // How far the darkening reaches ahead of the tear. The shader's CHAR.
        let char: CGFloat = 0.075
        let life = 1 - smoothstep(0.88, 1.0, progress)
        guard life > 0 else { return }

        let strips = 12
        for s in 0..<strips {
            // From just behind the tear to the outer edge of the char.
            let d0 = -0.02 + (char + 0.02) * CGFloat(s) / CGFloat(strips)
            let d1 = -0.02 + (char + 0.02) * CGFloat(s + 1) / CGFloat(strips)
            let mid = (d0 + d1) / 2

            let hot = 1 - min(max(mid / char, 0), 1)

            var colour = charred
            colour = mix(colour, emberColour, smoothstep(0.28, 0.62, hot))
            colour = mix(colour, flame, smoothstep(0.68, 0.88, hot))
            colour = mix(colour, core, smoothstep(0.93, 1.00, hot))

            let alpha = smoothstep(-0.02, 0.002, mid) * (0.35 + 0.65 * hot) * life
            guard alpha > 0.01 else { continue }

            var band = Path()
            band.move(to: CGPoint(x: points[0].x, y: points[0].y + d0 * size.height))
            for p in points { band.addLine(to: CGPoint(x: p.x, y: p.y + d0 * size.height)) }
            for p in points.reversed() { band.addLine(to: CGPoint(x: p.x, y: p.y + d1 * size.height)) }
            band.closeSubpath()

            c.fill(band, with: .color(Color(red: colour.0, green: colour.1, blue: colour.2)
                .opacity(alpha)))
        }
    }

    /// Sparks thrown off the front. `uMode` two.
    ///
    /// Twenty four, each entirely determined by its index and the seed, so
    /// there is no state to keep and nothing to update per frame: the same
    /// bargain the shader makes.
    private func embers(_ c: GraphicsContext, _ canvas: CGSize, _ bubble: CGSize, _ progress: CGFloat) {
        // Where the message sits inside the larger canvas.
        let originX: CGFloat = 20
        let originY: CGFloat = emberRoom

        for i in 0..<24 {
            let fi = CGFloat(i)
            let r1 = hash(CGPoint(x: fi, y: seed))
            let r2 = hash(CGPoint(x: fi + 31, y: seed))
            let r3 = hash(CGPoint(x: fi + 71, y: seed))

            // Each spark leaves when the front reaches its row, so they come
            // off the flame rather than all at once.
            let born = 0.06 + r2 * 0.72
            let age = (progress - born) / max(1 - born, 0.001)
            guard age >= 0, age <= 1 else { continue }

            let start = CGPoint(x: originX + r1 * bubble.width,
                                y: originY + born * bubble.height)

            // Up, with sideways drift, decelerating. In units of the message's
            // own height, so a small message throws small sparks.
            let rise = bubble.height * (0.5 + r3 * 1.7)
            let drift = bubble.width * (r1 - 0.5) * 0.7

            let at = CGPoint(x: start.x + drift * age,
                             y: start.y - rise * (age - 0.35 * age * age))

            // Shrinking and cooling as it goes. Yellow when new, deep red when
            // old, which is what an ember does.
            let radius = mix(3.4, 1.0, age)
            let fade = (1 - age) * (1 - age)
            let tint = mix((1.0, 0.85, 0.45), (0.85, 0.12, 0.02),
                           smoothstep(0.15, 0.85, age))

            c.fill(
                Path(ellipseIn: CGRect(x: at.x - radius, y: at.y - radius,
                                       width: radius * 2, height: radius * 2)),
                with: .color(Color(red: tint.0, green: tint.1, blue: tint.2)
                    .opacity(fade)))
        }
    }

    // MARK: - Running it

    private func progress(at now: Date) -> CGFloat {
        guard let began else { return 0 }
        return min(1, max(0, CGFloat(now.timeIntervalSince(began) / burnDuration)))
    }

    private func start() async {
        Haptics.burning()
        try? await Task.sleep(nanoseconds: 30_000_000)
        began = .now

        try? await Task.sleep(nanoseconds: UInt64((burnDuration + 0.2) * 1_000_000_000))
        onGone()
    }
}

// MARK: - The shader's own arithmetic

/// How long the fire takes.
///
/// `lib/ui/burn.dart` gives it twelve seconds and explains why: it happens
/// rarely, to one message, because somebody chose it, and watching it happen is
/// the point rather than an ornament on the way somewhere else. Eight here, and
/// only because a raised wrist does not stay raised for twelve.
private let burnDuration: TimeInterval = 8

private let charred = (0.06, 0.035, 0.03)
private let emberColour = (0.72, 0.13, 0.01)
private let flame = (1.00, 0.48, 0.05)
private let core = (1.00, 0.93, 0.72)

private func hash(_ p: CGPoint) -> CGFloat {
    var x = (p.x * 123.34).truncatingRemainder(dividingBy: 1)
    var y = (p.y * 456.21).truncatingRemainder(dividingBy: 1)
    if x < 0 { x += 1 }
    if y < 0 { y += 1 }
    let d = x * (x + 45.32) + y * (y + 45.32)
    x += d
    y += d
    let r = (x * y).truncatingRemainder(dividingBy: 1)
    return r < 0 ? r + 1 : r
}

private func valueNoise(_ p: CGPoint) -> CGFloat {
    let i = CGPoint(x: floor(p.x), y: floor(p.y))
    let f = CGPoint(x: p.x - i.x, y: p.y - i.y)
    let u = CGPoint(x: f.x * f.x * (3 - 2 * f.x), y: f.y * f.y * (3 - 2 * f.y))

    let a = hash(i)
    let b = hash(CGPoint(x: i.x + 1, y: i.y))
    let c = hash(CGPoint(x: i.x, y: i.y + 1))
    let d = hash(CGPoint(x: i.x + 1, y: i.y + 1))

    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y)
}

/// Two octaves. Enough to wander, not enough to be busy.
private func shape(_ p: CGPoint, _ scale: CGFloat, _ offset: CGFloat) -> CGFloat {
    let q = CGPoint(x: p.x * scale + offset, y: p.y * scale + offset)
    return valueNoise(q) * 0.66
        + valueNoise(CGPoint(x: q.x * 2.07, y: q.y * 2.07)) * 0.34
}

private func mix(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }

private func mix(_ a: (Double, Double, Double), _ b: (Double, Double, Double),
                 _ t: CGFloat) -> (Double, Double, Double) {
    let f = Double(t)
    return (a.0 + (b.0 - a.0) * f, a.1 + (b.1 - a.1) * f, a.2 + (b.2 - a.2) * f)
}

private func smoothstep(_ edge0: CGFloat, _ edge1: CGFloat, _ x: CGFloat) -> CGFloat {
    let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
    return t * t * (3 - 2 * t)
}
