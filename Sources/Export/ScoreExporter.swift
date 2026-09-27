import CoreGraphics
import Foundation
import UIKit

/// EngravedScore を PNG / PDF に書き出す。
/// ScorePainter は素の Quartz 向き(y-up)のコンテキストを要求するため、
/// ビットマップ/PDF とも生の CGContext を使う(UIKit ラッパーは y-down)。
public enum ScoreExporter {
    /// 譜面の背景色(ScoreView と同系色)
    private static let bg = CGColor(red: 0.97, green: 0.97, blue: 0.95, alpha: 1)

    /// 楽譜全体を 1 枚の PNG にする。
    public static func pngData(tune: ABCTune, width: CGFloat = 1200,
                               scale: CGFloat = 2) -> Data? {
        let score = ScoreEngraver.engrave(tune, width: width, header: true)
        let w = Int(score.size.width * scale)
        let h = Int(score.size.height * scale)
        guard w > 0, h > 0, let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        ctx.setFillColor(bg)
        ctx.fill(CGRect(origin: .zero, size: score.size))
        ScorePainter.draw(score, in: ctx, highlight: [], cursorID: nil)
        guard let image = ctx.makeImage() else { return nil }
        return UIImage(cgImage: image).pngData()
    }

    /// 楽譜全体を 1 ページの PDF にする。
    public static func pdfData(tune: ABCTune, width: CGFloat = 800) -> Data? {
        let score = ScoreEngraver.engrave(tune, width: width, header: true)
        var mediaBox = CGRect(origin: .zero, size: score.size)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
        else { return nil }
        ctx.beginPDFPage(nil)
        ctx.setFillColor(bg)
        ctx.fill(mediaBox)
        ScorePainter.draw(score, in: ctx, highlight: [], cursorID: nil)
        ctx.endPDFPage()
        ctx.closePDF()
        return data as Data
    }
}
