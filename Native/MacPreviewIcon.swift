import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum IconError: Error {
    case invalidArtwork
    case cannotCreateIcon
}

let input = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
guard let source = CGImageSourceCreateWithURL(input as CFURL, nil),
      let artwork = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    throw IconError.invalidArtwork
}

let size = 1024
let tile = CGRect(x: 88, y: 88, width: 848, height: 848)
guard let canvas = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    throw IconError.cannotCreateIcon
}
canvas.clear(CGRect(x: 0, y: 0, width: size, height: size))
canvas.interpolationQuality = .high
canvas.addPath(CGPath(roundedRect: tile, cornerWidth: 212, cornerHeight: 212, transform: nil))
canvas.clip()
canvas.draw(artwork, in: tile)

guard let image = canvas.makeImage(),
      let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    throw IconError.cannotCreateIcon
}
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else { throw IconError.cannotCreateIcon }
