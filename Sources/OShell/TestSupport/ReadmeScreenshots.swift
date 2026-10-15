// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit
import QuartzCore
import SwiftTerm
import OShellCore

/// Reproducible documentation images from real views and synthetic data only.
enum ReadmeScreenshots {
    private final class Files: RemoteFileBackend {
        let description = "SFTP · 192.0.2.20"
        func connect() throws {}
        func canonicalPath(_ path:String) throws -> String { path }
        func list(_ path:String) throws -> [RemoteFileEntry] {
            let names = ["config", "logs", "releases", "app.yaml", "deploy.sh", "Dockerfile", "healthcheck.py", "README.md", "release-0.2.74.tar.gz", "service.log", "status.json"]
            return names.enumerated().map { index,name in
                let directory = index < 3
                return RemoteFileEntry(name:name,size:directory ? 4096 : UInt64([1842,3072,512,2048,5680,12582912,524288,960][index-3]),modified:Date(timeIntervalSince1970:1792022400),directory:directory,symbolicLink:false,permissions:directory ? 0o40755 : (name == "deploy.sh" ? 0o100755 : 0o100644),owner:"deploy",group:"app")
            }
        }
        func upload(_ local:URL,to remote:String,progress:@escaping(UInt64,UInt64)->Void) throws { throw ModelError.invalid("文档预览不执行文件操作") }
        func download(_ remote:String,to local:URL,progress:@escaping(UInt64,UInt64)->Void) throws { throw ModelError.invalid("文档预览不执行文件操作") }
        func mkdir(_ path:String) throws {}
        func rename(_ source:String,to destination:String) throws {}
        func remove(_ path:String,directory:Bool) throws {}
        func cancel() {}
    }
    static func run(_ workspace:WorkspaceController) {
        guard let output = ProcessInfo.processInfo.environment["OSHELL_README_OUTPUT"] else { return }
        let directory = URL(fileURLWithPath:output).deletingLastPathComponent()
        var checks = [String:Bool]()
        func snapshot(_ window:NSWindow,_ name:String) {
            guard let root = window.contentView else { checks[name] = false; return }
            root.wantsLayer = true
            let previous = NSAppearance.current; NSAppearance.current = root.effectiveAppearance
            let background = NSColor.windowBackgroundColor.cgColor
            root.layer?.backgroundColor = background; NSAppearance.current = previous
            root.layoutSubtreeIfNeeded(); root.displayIfNeeded(); window.displayIfNeeded(); CATransaction.flush()
            let scale:CGFloat = 2
            guard let context = CGContext(data:nil,width:Int(root.bounds.width*scale),height:Int(root.bounds.height*scale),bitsPerComponent:8,bytesPerRow:0,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { checks[name] = false; return }
            context.scaleBy(x:scale,y:scale); context.setFillColor(background); context.fill(root.bounds); root.layer?.render(in:context)
            guard let image = context.makeImage(), let data = NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:]) else { checks[name] = false; return }
            do { try data.write(to:directory.appendingPathComponent(name+".png")); checks[name] = true }
            catch { checks[name] = false }
        }
        var config = workspace.configuration
        config.preferences.masterWarningAcknowledged = true
        config.profiles = ["api-01", "api-02", "web-01", "web-02", "worker-01", "worker-02", "文件分发"].enumerated().map { index,name in
            SessionProfile(name:name,group:"生产/应用",kind:index == 6 ? .sftp : .ssh,host:"192.0.2.\(10+index)",username:"deploy")
        }
        config.directories = ["生产/应用/灰度", "生产/应用/归档", "测试", "基础设施"]
        checks["isolatedFixtureSaved"] = workspace.saveConfiguration(config)
        ApplicationAppearance.apply(.light)
        let sessions = SessionManager(workspace:workspace)
        sessions.show(); sessions.reveal(config.profiles[0])
        sessions.window?.setContentSize(NSSize(width:1000,height:560))
        DispatchQueue.main.asyncAfter(deadline:.now()+0.4) {
            if let window = sessions.window {
                snapshot(window,"readme-sessions")
                sessions.close()
            }
            let files = RemoteFileWindow(workspace:workspace,backendFactory:{ _ in Files() })
            files.window?.setContentSize(NSSize(width:1100,height:560))
            let profile = SessionProfile(name:"文件分发",group:"生产/应用",kind:.sftp,host:"192.0.2.20",username:"deploy")
            files.show(profile:profile,directory:"/srv/app")
            let deadline = Date().addingTimeInterval(8)
            func waitForFiles() {
                if files.selectedSession?.connected == true && files.selectedSession?.listedNames.count == 11 {
                    files.selectedSession?.setTransferRateLimit(5*1024*1024)
                    DispatchQueue.main.asyncAfter(deadline:.now()+0.3) {
                        if let window = files.window { snapshot(window,"readme-files") }
                        files.close(); finish()
                    }
                } else if Date() >= deadline { checks["filesReady"] = false; files.close(); finish() }
                else { DispatchQueue.main.asyncAfter(deadline:.now()+0.1) { waitForFiles() } }
            }
            func finish() {
                let report:[String:Any] = ["passed":checks.values.allSatisfy { $0 } && checks.count == 3,"checks":checks]
                try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:output))
                workspace.shutdown(); NSApp.terminate(nil)
            }
            waitForFiles()
        }
    }
}

extension ReadmeScreenshots {
    static func runSettings(_ workspace:WorkspaceController) {
        guard let output = ProcessInfo.processInfo.environment["OSHELL_README_SETTINGS_OUTPUT"] else { return }
        let folder = URL(fileURLWithPath:output).deletingLastPathComponent()
        let pages = [("general","常规","字体、历史行数与复制粘贴"),("appearance","主题与配色","独立配色方案与实时预览"),("shortcuts","快捷键","自定义组合键与冲突检查"),("text","文字显示","彩色 Emoji、图标与宽字符"),("clock","本地时钟","悬浮位置、字体与透明度"),("security","安全","主密码保护与 Touch ID 解锁")]
        var images = [CGImage](), checks = [String:Bool]()
        func allViews(_ view:NSView)->[NSView] { [view]+view.subviews.flatMap(allViews) }
        func render(_ view:NSView)->CGImage? {
            view.wantsLayer = true; view.layer?.backgroundColor = NSColor.white.cgColor
            view.layoutSubtreeIfNeeded(); view.displayIfNeeded(); CATransaction.flush()
            let scale:CGFloat = 2, bounds = view.bounds
            guard let context = CGContext(data:nil,width:Int(bounds.width*scale),height:Int(bounds.height*scale),bitsPerComponent:8,bytesPerRow:0,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.scaleBy(x:scale,y:scale); context.setFillColor(NSColor.white.cgColor); context.fill(bounds)
            context.saveGState(); context.clip(to:bounds); view.layer?.render(in:context); context.restoreGState()
            // Terminal previews use their real native renderer with a fresh text
            // origin, avoiding the translated glyph caches of offscreen layers.
            for terminal in allViews(view).compactMap({ $0 as? SwiftTerm.TerminalView }) where !terminal.isHiddenOrHasHiddenAncestor {
                let box = terminal.bounds
                guard box.width > 0, box.height > 0, let text = CGContext(data:nil,width:Int(ceil(box.width*scale)),height:Int(ceil(box.height*scale)),bitsPerComponent:8,bytesPerRow:0,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
                text.scaleBy(x:scale,y:scale); text.textMatrix = .identity; text.textPosition = .zero
                NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext:text,flipped:terminal.isFlipped)
                terminal.draw(box); NSGraphicsContext.restoreGraphicsState()
                if let image = text.makeImage() {
                    let rect = terminal.convert(box,to:view)
                    context.saveGState(); context.clip(to:rect)
                    context.setFillColor(terminal.nativeBackgroundColor.cgColor); context.fill(rect); context.draw(image,in:rect); context.restoreGState()
                }
            }
            return context.makeImage()
        }
        func compose() {
            guard images.count == pages.count else { checks["sixPages"] = false; return }
            let margin:CGFloat = 24, cardWidth:CGFloat = 820, cardHeight:CGFloat = 580, header:CGFloat = 102
            let width = margin*3+cardWidth*2, height = header+margin*4+cardHeight*3, scale:CGFloat = 1.5
            guard let context = CGContext(data:nil,width:Int(width*scale),height:Int(height*scale),bitsPerComponent:8,bytesPerRow:0,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            context.scaleBy(x:scale,y:scale)
            context.setFillColor(NSColor(srgbRed:0.94,green:0.95,blue:0.96,alpha:1).cgColor); context.fill(CGRect(x:0,y:0,width:width,height:height))
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext:context,flipped:false)
            func label(_ value:String,_ point:NSPoint,_ size:CGFloat,_ color:NSColor,_ weight:NSFont.Weight = .regular) {
                (value as NSString).draw(at:point,withAttributes:[.font:NSFont.systemFont(ofSize:size,weight:weight),.foregroundColor:color])
            }
            let ink = NSColor(srgbRed:0.12,green:0.15,blue:0.19,alpha:1)
            label("OShell · 设置一览",NSPoint(x:margin,y:height-52),28,ink,.semibold)
            label("六个常用设置页 · 实际界面与示例配置",NSPoint(x:margin,y:height-80),14,.darkGray)
            for (index,image) in images.enumerated() {
                let x = margin+CGFloat(index%2)*(cardWidth+margin), y = height-header-margin-CGFloat(index/2+1)*cardHeight-CGFloat(index/2)*margin
                let rect = NSRect(x:x,y:y,width:cardWidth,height:cardHeight)
                NSColor.white.setFill(); NSBezierPath(roundedRect:rect,xRadius:12,yRadius:12).fill()
                label(String(format:"%02d",index+1),NSPoint(x:x+18,y:y+cardHeight-34),17,NSColor(srgbRed:0.85,green:0.32,blue:0.12,alpha:1),.semibold)
                label(pages[index].1,NSPoint(x:x+54,y:y+cardHeight-34),20,ink,.semibold)
                label(pages[index].2,NSPoint(x:x+54,y:y+cardHeight-57),12,.darkGray)
                let target = CGRect(x:x+8,y:y+8,width:cardWidth-16,height:cardHeight-80)
                context.saveGState(); context.clip(to:target); context.interpolationQuality = .high; context.draw(image,in:target); context.restoreGState()
            }
            NSGraphicsContext.restoreGraphicsState()
            if let image = context.makeImage(), let png = NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:]) {
                do { try png.write(to:folder.appendingPathComponent("readme-settings-grid.png")); checks["gridWritten"] = true } catch { checks["gridWritten"] = false }
            }
        }
        workspace.configuration.preferences.interfaceTheme = .light
        workspace.configuration.preferences.colorSchemeID = "graphite-flame"
        workspace.configuration.preferences.fontName = "Menlo-Regular"
        workspace.configuration.preferences.fontSize = 13
        workspace.configuration.preferences.metal = false
        workspace.configuration.preferences.terminalClockEnabled = true
        ApplicationAppearance.apply(.light)
        let timer = Timer(timeInterval:0.3,repeats:false) { _ in
            guard let window = NSApp.modalWindow, let root = window.contentView,
                  let tabs = allViews(root).compactMap({ $0 as? NSTabView }).first else { checks["settingsOpened"] = false; NSApp.abortModal(); return }
            func capturePage(_ index:Int) {
                guard index < pages.count else { compose(); _ = PopupKeyboard.dismiss(window:window); return }
                guard let item = tabs.tabViewItems.first(where:{ $0.identifier as? String == pages[index].0 }), let view = item.view else { checks[pages[index].0] = false; _ = PopupKeyboard.dismiss(window:window); return }
                tabs.selectTabViewItem(item); root.layoutSubtreeIfNeeded()
                let capture = Timer(timeInterval:0.3,repeats:false) { _ in
                    allViews(view).compactMap { $0 as? TerminalClockView }.forEach { $0.updateText("2026-10-16 10:24:36") }
                    if let image = render(view) {
                        images.append(image); checks[pages[index].0] = true
                        try? NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:])?.write(to:folder.appendingPathComponent("readme-setting-"+pages[index].0+".png"))
                    } else { checks[pages[index].0] = false }
                    capturePage(index+1)
                }
                RunLoop.main.add(capture,forMode:.common); RunLoop.main.add(capture,forMode:.modalPanel)
            }
            capturePage(0)
        }
        RunLoop.main.add(timer,forMode:.common); RunLoop.main.add(timer,forMode:.modalPanel)
        workspace.showPreferences()
        let report:[String:Any] = ["passed":checks.count == 7 && checks.values.allSatisfy { $0 },"checks":checks]
        try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:output))
        workspace.shutdown(); NSApp.terminate(nil)
    }
}
