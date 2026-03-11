import SwiftUI
import WebKit

/// A SwiftUI view that renders SVG images using WebKit
struct SVGImageView: NSViewRepresentable {
    let svgName: String
    let width: CGFloat
    let height: CGFloat

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // Try multiple paths to find the SVG
        var svgPath: String?
        var svgString: String?

        // Method 1: Bundle.main.path
        if let path = Bundle.main.path(forResource: svgName, ofType: "svg") {
            svgPath = path
            print("✓ Found SVG via Bundle.main.path: \(path)")
        }
        // Method 2: resourcePath
        else if let resourcePath = Bundle.main.resourcePath {
            let path = (resourcePath as NSString).appendingPathComponent("\(svgName).svg")
            if FileManager.default.fileExists(atPath: path) {
                svgPath = path
                print("✓ Found SVG via resourcePath: \(path)")
            } else {
                print("✗ SVG not found at: \(path)")
            }
        }

        // Try to load the SVG content
        if let path = svgPath, let content = try? String(contentsOfFile: path, encoding: .utf8) {
            svgString = content
            print("✓ Loaded SVG content (\(content.count) characters)")
        } else {
            print("✗ Could not load SVG: \(svgName)")
            // Show error in webview
            webView.loadHTMLString("<html><body style='background:red;color:white;'>SVG Not Found: \(svgName)</body></html>", baseURL: nil)
            return
        }

        guard let svg = svgString else { return }

        let htmlString = """
        <!DOCTYPE html>
        <html>
        <head>
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <style>
                body {
                    margin: 0;
                    padding: 0;
                    display: flex;
                    justify-content: center;
                    align-items: center;
                    width: 100%;
                    height: 100%;
                    background: transparent;
                }
                svg {
                    width: 100%;
                    height: 100%;
                }
            </style>
        </head>
        <body>
            \(svg)
        </body>
        </html>
        """

        print("✓ Loading SVG into WebView")
        webView.loadHTMLString(htmlString, baseURL: nil)
    }
}

/// Alternative: Load SVG from file path (for Assets folder)
struct SVGImage: View {
    let svgPath: String
    let width: CGFloat
    let height: CGFloat

    @State private var nsImage: NSImage?

    var body: some View {
        Group {
            if let nsImage = nsImage {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: width, height: height)
            } else {
                // Fallback while loading
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: width, height: height)
                    .overlay(
                        Text("Loading...")
                            .font(.caption)
                            .foregroundStyle(.gray)
                    )
            }
        }
        .onAppear {
            loadSVG()
        }
    }

    private func loadSVG() {
        guard let svgData = try? Data(contentsOf: URL(fileURLWithPath: svgPath)) else {
            print("Failed to load SVG from: \(svgPath)")
            return
        }

        // Create NSImage from SVG data with explicit size
        if let image = NSImage(data: svgData) {
            // Set the size explicitly
            image.size = NSSize(width: width, height: height)
            nsImage = image
            print("✓ SVG loaded successfully: \(svgPath) at \(width)x\(height)")
        } else {
            print("Failed to create NSImage from SVG data")
        }
    }
}
