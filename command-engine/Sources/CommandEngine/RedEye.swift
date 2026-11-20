import Foundation

/// Red eye and pet eye, by hand (no face detection): a tap on the eye (a circle as big as the brush)
/// or a line drawn around it (the circle around the line). Inside the pupil part of the circle
/// (Pupil Size), red eye takes the red out of reddish pixels and darkens them (Pupil Darken); pet
/// eye turns the bright glow of an animal's eye into a dark pupil and can add a small catchlight.
enum RedEye {
    /// How far out from the centre the pupil reaches, as a share of the circle (Pupil Size 0…100).
    static func reach(pupilSize: Double) -> Double {
        0.3 + 0.7 * Swift.min(100, Swift.max(0, pupilSize)) / 100
    }

    /// One eye fixed in `pixels` (a picture of `box`); the eye circle's centre and radius in pixels of
    /// the whole picture.
    static func fix(_ pixels: inout RGBBuffer, box: PixelBox, centre: (x: Double, y: Double), radius: Double, pet: Bool,
                    pupilSize: Double, darken: Double, catchlight: Bool) {
        let reach = reach(pupilSize: pupilSize) * radius
        let dark = Float(Swift.min(1, Swift.max(0, darken / 100)))
        for y in 0..<box.height {
            for x in 0..<box.width {
                let dx = Double(box.x0 + x) + 0.5 - centre.x, dy = Double(box.y0 + y) + 0.5 - centre.y
                let d = (dx * dx + dy * dy).squareRoot()
                guard d < reach else { continue }
                let inPupil = Float(1 - Effects.smoothstep(0.8 * reach, reach, d))
                let i = 3 * (y * box.width + x)
                let r = pixels.pixels[i], g = pixels.pixels[i + 1], b = pixels.pixels[i + 2]
                if pet {
                    // The glow: bright pixels of any colour, turned into a dark grey pupil.
                    let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
                    let glow = Float(Effects.smoothstep(0.25, 0.6, Double(luma))) * inPupil
                    let pupil = 0.15 - 0.1 * dark
                    for c in 0..<3 { pixels.pixels[i + c] += (pupil - pixels.pixels[i + c]) * glow }
                } else {
                    // Red: red well above green and blue (flash pupils 0.7 or more; skin and brown irises
                    // stay under 0.35); it becomes their grey, darkened.
                    let redness = (r - Swift.max(g, b)) / Swift.max(r, 0.001)
                    let k = Float(Effects.smoothstep(0.35, 0.6, Double(redness)) * Effects.smoothstep(0.08, 0.2, Double(r))) * inPupil
                    let grey = (g + b) / 2 * (1 - 0.8 * dark)
                    for c in 0..<3 { pixels.pixels[i + c] += (grey - pixels.pixels[i + c]) * k }
                }
            }
        }
        guard pet, catchlight else { return }
        // A small soft white dot up and to the left of the middle.
        let spot = (x: centre.x - 0.3 * reach, y: centre.y - 0.3 * reach), size = Swift.max(1.5, 0.2 * reach)
        for y in 0..<box.height {
            for x in 0..<box.width {
                let dx = Double(box.x0 + x) + 0.5 - spot.x, dy = Double(box.y0 + y) + 0.5 - spot.y
                let d = (dx * dx + dy * dy).squareRoot() / size
                guard d < 1 else { continue }
                let k = Float(1 - Effects.smoothstep(0.4, 1, d))
                let i = 3 * (y * box.width + x)
                for c in 0..<3 { pixels.pixels[i + c] += (0.95 - pixels.pixels[i + c]) * k }
            }
        }
    }
}
