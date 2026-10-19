import AppKit
import DittoMacKit

/// 打包条目(导出/导入 .dto)的面板与入库接线。
/// 格式与 zlib/DROPFILES 细节在 DittoMacKit.ClipPackage;此处只做 UI 流程:
/// 导出 = 选中条目 → 存面板;导入 = 开面板 → 读包 → 逐条插入当前组(去重生效)。
enum ClipPackageUI {

    /// 包文件扩展名(上游用 .dto;此处按任务口径 .dto,文件头注明互导待验证)
    static let fileExtension = "dittoexport"

    // MARK: - 导出(选中条目 → 包文件)

    /// 导出选中条目;返回 true = 已写文件(错误已弹窗提示)
    @discardableResult
    static func runExportPanel(store: ClipStoring, items: [ClipItem]) -> Bool {
        guard !items.isEmpty else { return false }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.data]
        panel.nameFieldStringValue = "ditto-clips-\(Int(Date().timeIntervalSince1970)).\(fileExtension)"
        var confirmedURL: URL?
        // begin sheet 模式在浮动面板上不可靠,这里用模态运行(与菜单动作同步语义一致)
        if panel.runModal() == .OK {
            confirmedURL = panel.url
        }
        guard let url = confirmedURL else { return false }

        // 组装包条目:描述 = 标题或派生描述(与列表行显示一致);时间 = created_at;
        // 格式 = store.formats(已知格式代表性 UTI 在前)+ 附加格式,再转 Windows 名
        let packages = items.map { item -> PackagedClip in
            let payload = store.payload(id: item.id)
            let descSource: String?
            if let title = item.title, !title.isEmpty { descSource = title }
            else if item.isGroup { descSource = item.text }
            else { descSource = payload?.text ?? item.text }
            let raw = payload ?? RawClip(text: descSource)
            return PackagedClip(desc: ClipDescription.build(text: descSource),
                                createdAt: item.createdAt,
                                formats: ClipPackage.formats(fromRaw: raw))
        }
        let ok = ClipPackage.export(clips: packages, to: url)
        let alert = NSAlert()
        if ok {
            alert.messageText = L10n.pkgExportDone
            alert.informativeText = "\(url.path)\n" + L10n.pkgInteropNote
        } else {
            alert.alertStyle = .critical
            alert.messageText = L10n.pkgExportFailed
        }
        alert.addButton(withTitle: L10n.dlgOk)
        alert.runModal()
        PerfLog.event("PACKAGE_EXPORTED", "ok=\(ok) clips=\(packages.count)")
        return ok
    }

    // MARK: - 导入(包文件 → 当前组)

    /// 打开导入面板;完成回调带回成功导入条数(0 = 取消/失败,失败已弹窗)
    static func runImportPanel(store: ClipStoring, parentID: Int64, completion: ((Int) -> Void)? = nil) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = L10n.pkgImportPrompt
        panel.begin { response in
            guard response == .OK, let url = panel.url else {
                completion?(0)
                return
            }
            var imported = 0
            var failed = 0
            if let packages = ClipPackage.importClips(from: url) {
                for package in packages {
                    let raw = ClipPackage.rawClip(from: package.formats)
                    var clip = raw
                    clip.appName = L10n.importedAppName
                    // 走常规插入:内容与既有条目相同会被去重置顶(与原版 AddToDB 一致)
                    if store.insert(clip, maxDataBytes: AppDelegate.maxDataBytesSetting(),
                                    parentID: parentID) != nil {
                        imported += 1
                    } else {
                        failed += 1
                    }
                }
            }
            DispatchQueue.main.async {
                if imported == 0, failed == 0 {
                    let alert = NSAlert()
                    alert.alertStyle = .warning
                    alert.messageText = L10n.pkgImportFailed
                    alert.addButton(withTitle: L10n.dlgOk)
                    alert.runModal()
                }
                completion?(imported)
            }
        }
    }
}
