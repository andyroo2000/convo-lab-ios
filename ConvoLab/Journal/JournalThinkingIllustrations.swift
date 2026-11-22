import UIKit

@MainActor
enum JournalThinkingIllustrations {
    static let images: [UIImage] = regions.enumerated().compactMap { index, region in
        guard let atlas = UIImage(named: "ThinkingAtlas\(index / 20)")?.cgImage,
              let crop = atlas.cropping(to: region) else { return nil }
        return UIImage(cgImage: crop)
    }

    private static let regions: [CGRect] = [
        CGRect(x: 45, y: 70, width: 260, height: 205),
        CGRect(x: 370, y: 45, width: 195, height: 230),
        CGRect(x: 620, y: 48, width: 270, height: 228),
        CGRect(x: 960, y: 44, width: 195, height: 230),
        CGRect(x: 1220, y: 65, width: 280, height: 205),
        CGRect(x: 68, y: 302, width: 220, height: 225),
        CGRect(x: 355, y: 320, width: 215, height: 200),
        CGRect(x: 610, y: 302, width: 300, height: 220),
        CGRect(x: 960, y: 300, width: 190, height: 230),
        CGRect(x: 1235, y: 292, width: 240, height: 235),
        CGRect(x: 36, y: 575, width: 270, height: 170),
        CGRect(x: 355, y: 570, width: 235, height: 175),
        CGRect(x: 655, y: 540, width: 220, height: 225),
        CGRect(x: 930, y: 585, width: 245, height: 160),
        CGRect(x: 1248, y: 540, width: 220, height: 235),
        CGRect(x: 32, y: 825, width: 276, height: 145),
        CGRect(x: 384, y: 780, width: 180, height: 230),
        CGRect(x: 610, y: 790, width: 275, height: 205),
        CGRect(x: 975, y: 780, width: 170, height: 220),
        CGRect(x: 1210, y: 800, width: 300, height: 205),
        CGRect(x: 42, y: 45, width: 250, height: 225),
        CGRect(x: 388, y: 38, width: 159, height: 239),
        CGRect(x: 609, y: 63, width: 278, height: 210),
        CGRect(x: 944, y: 52, width: 249, height: 225),
        CGRect(x: 1280, y: 51, width: 181, height: 215),
        CGRect(x: 51, y: 299, width: 228, height: 222),
        CGRect(x: 322, y: 310, width: 276, height: 196),
        CGRect(x: 610, y: 325, width: 289, height: 194),
        CGRect(x: 950, y: 300, width: 225, height: 224),
        CGRect(x: 1240, y: 307, width: 253, height: 211),
        CGRect(x: 44, y: 544, width: 251, height: 199),
        CGRect(x: 357, y: 516, width: 211, height: 228),
        CGRect(x: 617, y: 565, width: 267, height: 169),
        CGRect(x: 950, y: 555, width: 231, height: 179),
        CGRect(x: 1215, y: 555, width: 286, height: 185),
        CGRect(x: 30, y: 772, width: 274, height: 221),
        CGRect(x: 369, y: 792, width: 193, height: 203),
        CGRect(x: 662, y: 766, width: 182, height: 232),
        CGRect(x: 928, y: 793, width: 275, height: 181),
        CGRect(x: 1245, y: 779, width: 227, height: 212),
    ]
}
