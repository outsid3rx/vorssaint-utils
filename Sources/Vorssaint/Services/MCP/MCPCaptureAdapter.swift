// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import ImageIO
import UniformTypeIdentifiers

/// One in-memory, user-selected capture. No capture is copied to the system
/// clipboard, saved to a file, or sent before the person confirms its transfer.
final class MCPCaptureAdapter {
    static let shared = MCPCaptureAdapter()

    private var store = MCPCaptureStore()
    private var selection: ScreenshotSelectionController?
    private var timer: Timer?
    private var approval: NSAlert?
    private var screenLocked = false
    private var screenLockObservers: [NSObjectProtocol] = []
    private init() {
        let center = DistributedNotificationCenter.default()
        screenLockObservers = [
            center.addObserver(forName: Notification.Name("com.apple.screenIsLocked"),
                               object: nil, queue: .main) { [weak self] _ in
                self?.screenLocked = true
                self?.clear()
            },
            center.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"),
                               object: nil, queue: .main) { [weak self] _ in
                self?.screenLocked = false
            },
        ]
        screenLocked = KeepAwakeAutomationSupport.isScreenLocked(
            sessionDictionary: CGSessionCopyCurrentDictionary() as? [String: Any])
    }

    private var allowed: Bool {
        UserDefaults.standard.bool(forKey: DefaultsKey.mcpEnabled)
            && UserDefaults.standard.bool(forKey: DefaultsKey.mcpCaptureEnabled)
            && SessionActivity.shared.isActive
            && !screenLocked
            && !KeepAwakeAutomationSupport.isScreenLocked(
                sessionDictionary: CGSessionCopyCurrentDictionary() as? [String: Any])
    }
    private var contentAllowed: Bool {
        allowed && UserDefaults.standard.bool(forKey: DefaultsKey.mcpCaptureContentEnabled)
    }

    func execute(_ request: MCPIPCRequest) -> MCPIPCResponse? {
        precondition(Thread.isMainThread)
        switch request.command {
        case "capture_start":
            guard request.id == nil, request.minutes == nil, request.value == nil,
                  request.muted == nil, request.offset == nil, request.outputOffset == nil,
                  request.systemAudio == nil, request.microphone == nil,
                  let mode = request.action, MCPCapturePolicy.canStart(mode: mode) else {
                return MCPIPCResponse(ok: false, error: "invalid_arguments")
            }
            return start(mode)
        case "capture_status", "capture_discard", "capture_read":
            guard request.minutes == nil, request.value == nil, request.muted == nil,
                  request.action == nil, request.outputOffset == nil,
                  request.systemAudio == nil, request.microphone == nil,
                  let id = request.id, UUID(uuidString: id) != nil,
                  (request.command == "capture_read" || request.offset == nil) else {
                return MCPIPCResponse(ok: false, error: "invalid_arguments")
            }
            maintain()
            guard let current = store.operation, current.id == id else { return MCPIPCResponse(ok: false, error: "capture_not_found") }
            if request.command == "capture_status" { return status(current) }
            if request.command == "capture_discard" {
                clear()
                return response(["id": id, "status": "discarded"])
            }
            guard contentAllowed, CGPreflightScreenCaptureAccess() else {
                clear()
                return MCPIPCResponse(ok: false, error: "capture_content_disabled")
            }
            let offset = request.offset ?? 0
            switch store.read(id: id, offset: offset, now: Date()) {
            case .failure(.notFound): return MCPIPCResponse(ok: false, error: "capture_not_found")
            case .failure(.notReady): return MCPIPCResponse(ok: false, error: "capture_not_ready")
            case .failure(.invalidOffset): return MCPIPCResponse(ok: false, error: "invalid_offset")
            case .success(let chunk):
                let done = chunk.nextOffset == nil
                let result = response(["id": id, "mime_type": chunk.mime, "offset": chunk.offset,
                                       "total_bytes": chunk.total, "data_base64": chunk.data.base64EncodedString(),
                                       "next_offset": chunk.nextOffset as Any? ?? NSNull(),
                                       "complete": done])
                if done { clear() }
                return result
            }
        default:
            return nil
        }
    }

    private func start(_ mode: String) -> MCPIPCResponse {
        guard allowed else { return MCPIPCResponse(ok: false, error: "capture_disabled") }
        guard contentAllowed else { return MCPIPCResponse(ok: false, error: "capture_content_disabled") }
        guard (mode == "screenshot" ? AppFeature.screenshot : AppFeature.screenOCR).isAvailable else {
            return MCPIPCResponse(ok: false, error: "capture_feature_unavailable")
        }
        guard CGPreflightScreenCaptureAccess() else { return MCPIPCResponse(ok: false, error: "screen_recording_permission_required") }
        maintain()
        guard !ScreenshotSelectionController.isSessionOnScreen, !ScreenRecorderService.shared.hasActiveCapture,
              selection == nil, !store.blocksNewCapture, approval == nil else {
            return MCPIPCResponse(ok: false, error: "capture_busy")
        }
        clear()
        let id = UUID().uuidString
        store.begin(id: id, mode: mode)
        let controller = ScreenshotSelectionController(
            freeze: false, includePointer: false, showLastRegion: false,
            hideVorssaintWindows: UserDefaults.standard.bool(forKey: DefaultsKey.screenshotHideVorssaintWindows),
            protectedWindowIDs: {
                var result = ScreenCaptureService.shared.protectedWindowIDs
                if AppFeature.screenshot.isAvailable {
                    result.formUnion(ScreenshotService.shared.protectedWindowIDsForCapture(honoursVisibilityPreference: true))
                }
                if NotchSupport.isEnabled() { result.formUnion(NotchService.shared.protectedWindowIDs) }
                return result
            }, purpose: approvalStrings.title, mode: .image, supportsScrollingCapture: false)
        selection = controller
        installTimer()
        controller.begin { [weak self, weak controller] result in
            guard let self, let controller, self.selection === controller,
                  self.store.operation?.id == id else { return }
            self.selection = nil
            guard self.allowed, CGPreflightScreenCaptureAccess(),
                  (mode == "screenshot" ? AppFeature.screenshot : AppFeature.screenOCR).isAvailable else {
                self.clear(); return
            }
            switch result {
            case .captured(let capture): self.confirmAndProcess(capture.image, mode: mode, id: id)
            case .cancelled: self.completeWithoutData(.cancelled, id: id)
            default: self.completeWithoutData(.failed, id: id, error: "capture_failed")
            }
        }
        return response(["id": id, "status": "selecting"])
    }

    private func confirmAndProcess(_ image: CGImage, mode: String, id: String) {
        guard contentAllowed else { completeWithoutData(.denied, id: id, error: "capture_content_disabled"); return }
        guard store.awaitApproval(id: id) else { return }
        let alert = NSAlert()
        let strings = approvalStrings
        alert.messageText = strings.title
        alert.informativeText = mode == "screenshot" ? strings.image : strings.text
        alert.addButton(withTitle: strings.allow)
        alert.addButton(withTitle: strings.deny)
        approval = alert
        NSApp.activate(ignoringOtherApps: true)
        let answer = alert.runModal()
        alert.window.orderOut(nil)
        approval = nil
        guard store.operation?.id == id else { return }
        guard answer == .alertFirstButtonReturn, contentAllowed, CGPreflightScreenCaptureAccess() else {
            completeWithoutData(.denied, id: id, error: "transfer_denied"); return
        }
        guard store.approve(id: id) else { return }
        let removeLineBreaks = UserDefaults.standard.bool(forKey: DefaultsKey.screenOCRRemoveLineBreaks)
        let languages = MediaSupport.recognitionLanguages(for: L10n.shared.language.rawValue)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result: (Data, String)?
            if mode == "screenshot" {
                let data = NSMutableData()
                if let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) {
                    CGImageDestinationAddImage(destination, image, nil)
                    result = CGImageDestinationFinalize(destination) ? (data as Data, "image/png") : nil
                } else { result = nil }
            } else if mode == "qr" {
                result = BarcodeDetector.read(ScreenTextService.recognitionImage(image)).map {
                    (Data($0.payload.utf8), "text/plain; charset=utf-8")
                }
            } else {
                let outcome = ScreenTextService.outcome(for: ScreenTextService.recognitionImage(image), detectQRCodes: false,
                    removeLineBreaks: removeLineBreaks, fallbackLanguages: languages)
                if case .text(let text) = outcome { result = (Data(text.utf8), "text/plain; charset=utf-8") }
                else { result = nil }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.store.operation?.id == id, self.store.operation?.state == .processing else { return }
                guard self.contentAllowed, CGPreflightScreenCaptureAccess(),
                      (mode == "screenshot" ? AppFeature.screenshot : AppFeature.screenOCR).isAvailable else {
                    self.clear(); return
                }
                guard let result else { self.completeWithoutData(.failed, id: id, error: mode == "screenshot" ? "encoding_failed" : "no_result"); return }
                self.store.finish(id: id, data: result.0, mime: result.1, now: Date())
            }
        }
    }

    private func completeWithoutData(_ state: MCPCaptureStore.State, id: String, error: String? = nil) {
        store.terminal(id: id, state: state, error: error, now: Date())
    }

    private func status(_ current: MCPCaptureStore.Operation) -> MCPIPCResponse {
        var value: [String: Any] = ["id": current.id, "mode": current.mode, "status": current.state.rawValue]
        if let error = current.error { value["error"] = error }
        if current.state == .ready, contentAllowed, let data = current.data, let mime = current.mime {
            value["mime_type"] = mime; value["total_bytes"] = data.count
        }
        return response(value)
    }

    private func response(_ value: [String: Any]) -> MCPIPCResponse {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return MCPIPCResponse(ok: false, error: "encoding_failed") }
        return MCPIPCResponse(ok: true, payload: text)
    }

    private func installTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.maintain() }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func maintain() {
        guard let current = store.operation else { return }
        if !contentAllowed || !CGPreflightScreenCaptureAccess()
            || !(current.mode == "screenshot" ? AppFeature.screenshot : AppFeature.screenOCR).isAvailable
            || (current.expires.map { $0 <= Date() } ?? false) { clear() }
    }

    /// Called by the settings/runtime when an authorization changes. Closing
    /// an active selection and discarding data take effect immediately.
    func syncWithPermissions() {
        precondition(Thread.isMainThread)
        if !contentAllowed { clear() }
    }

    func clear() {
        store.discard()
        let currentSelection = selection
        selection = nil
        currentSelection?.cancel()
        if let approval, NSApp.modalWindow === approval.window { NSApp.stopModal(withCode: .abort) }
        timer?.invalidate(); timer = nil
    }

    private var approvalStrings: (title: String, image: String, text: String, allow: String, deny: String) {
        switch L10n.shared.language {
        case .ru:
            return ("Передать данные экрана агенту?", "Выбранный снимок будет передан ИИ-агенту без редактирования. На нём могут быть личные данные.", "Распознанный текст или QR-код с выбранной области будет передан ИИ-агенту. Он может содержать личные данные.", "Передать", "Отмена")
        case .uk:
            return ("Передати дані екрана агенту?", "Вибраний знімок буде передано ШІ-агенту без редагування. Він може містити особисті дані.", "Розпізнаний текст або QR-код буде передано ШІ-агенту. Він може містити особисті дані.", "Передати", "Скасувати")
        case .ptBR:
            return ("Compartilhar a tela com o agente?", "A imagem selecionada será enviada ao agente de IA sem edição e pode conter dados pessoais.", "O texto ou código QR reconhecido será enviado ao agente de IA e pode conter dados pessoais.", "Compartilhar", "Cancelar")
        case .tr:
            return ("Ekran içeriği ajanla paylaşılsın mı?", "Seçilen ekran görüntüsü düzenlenmeden yapay zekâ ajanına gönderilir ve özel bilgiler içerebilir.", "Tanınan metin veya QR kodu yapay zekâ ajanına gönderilir ve özel bilgiler içerebilir.", "Paylaş", "İptal")
        case .es:
            return ("¿Compartir el contenido de la pantalla con el agente?", "La captura seleccionada se enviará al agente de IA sin editar y puede contener datos privados.", "El texto o código QR reconocido se enviará al agente de IA y puede contener datos privados.", "Compartir", "Cancelar")
        case .sk:
            return ("Zdieľať obsah obrazovky s agentom?", "Vybraná snímka sa odošle AI agentovi bez úprav a môže obsahovať súkromné údaje.", "Rozpoznaný text alebo QR kód sa odošle AI agentovi a môže obsahovať súkromné údaje.", "Zdieľať", "Zrušiť")
        case .de:
            return ("Bildschirminhalt mit dem Agenten teilen?", "Der ausgewählte Screenshot wird unbearbeitet an den KI-Agenten gesendet und kann private Daten enthalten.", "Erkannter Text oder QR-Code wird an den KI-Agenten gesendet und kann private Daten enthalten.", "Teilen", "Abbrechen")
        case .fr:
            return ("Partager le contenu de l’écran avec l’agent ?", "La capture sélectionnée sera envoyée sans modification à l’agent IA et peut contenir des données privées.", "Le texte ou code QR reconnu sera envoyé à l’agent IA et peut contenir des données privées.", "Partager", "Annuler")
        case .it:
            return ("Condividere il contenuto dello schermo con l’agente?", "La schermata selezionata sarà inviata all’agente IA senza modifiche e potrebbe contenere dati privati.", "Il testo o codice QR riconosciuto sarà inviato all’agente IA e potrebbe contenere dati privati.", "Condividi", "Annulla")
        case .ja:
            return ("画面の内容をエージェントと共有しますか？", "選択したスクリーンショットは編集せずに AI エージェントに送信されます。個人情報が含まれる場合があります。", "認識されたテキストまたは QR コードが AI エージェントに送信されます。個人情報が含まれる場合があります。", "共有", "キャンセル")
        case .ko:
            return ("화면 내용을 에이전트와 공유할까요?", "선택한 스크린샷이 편집 없이 AI 에이전트에 전송됩니다. 개인 정보가 포함될 수 있습니다.", "인식된 텍스트 또는 QR 코드가 AI 에이전트에 전송됩니다. 개인 정보가 포함될 수 있습니다.", "공유", "취소")
        case .zhHans:
            return ("与代理共享屏幕内容？", "所选截图将未经编辑发送给 AI 代理，可能包含私人信息。", "识别出的文字或二维码将发送给 AI 代理，可能包含私人信息。", "共享", "取消")
        case .zhTW:
            return ("與代理程式分享螢幕內容？", "所選截圖將未經編輯傳送給 AI 代理程式，可能包含私人資訊。", "辨識出的文字或 QR 碼將傳送給 AI 代理程式，可能包含私人資訊。", "分享", "取消")
        case .zhHK:
            return ("與代理程式分享螢幕內容？", "所選截圖將未經編輯傳送給 AI 代理程式，可能包含私人資料。", "辨識出的文字或 QR 碼將傳送給 AI 代理程式，可能包含私人資料。", "分享", "取消")
        case .enUS:
            return ("Share screen content with the agent?", "The selected, unedited screenshot will be sent to the AI agent. It may contain private information.", "Recognized text or a QR code from the selected area will be sent to the AI agent. It may contain private information.", "Share", "Cancel")
        }
    }
}
