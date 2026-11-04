// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import ApplicationServices
import Darwin
import Foundation

/// Controls only a recording created by this MCP chooser. The user chooses
/// the actual region and audio options in the visible native selector.
final class MCPRecordingAdapter {
    static let shared = MCPRecordingAdapter()
    private let commands: Set<String> = ["recording_start", "recording_status", "recording_stop", "recording_set_paused", "recording_share", "recording_read"]
    private var ownerID: UUID?
    private var selection: ScreenshotSelectionController?
    private var options: ScreenCaptureSelectionOptions?
    private var phase = "idle"
    private var selectedSystemAudio = false
    private var selectedMicrophone = false
    private var exportFD: Int32 = -1
    private var exportSize: Int64 = 0
    private var exportModificationSeconds: Int = 0
    private var exportModificationNanos: Int = 0
    private var exportState = "not_exported"
    private var exportMIME = "application/octet-stream"
    private var exportNextOffset = 0
    private var exportExpiry: Date?
    private var approval: NSAlert?
    private var timer: Timer?
    private var screenLocked = false
    private var screenLockObservers: [NSObjectProtocol] = []

    private init() {
        let center = DistributedNotificationCenter.default()
        screenLockObservers = [
            center.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
                self?.screenLocked = true
                self?.stopOwnedCapture()
                self?.clearExport(state: "not_exported")
            },
            center.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
                self?.screenLocked = false
            }
        ]
        screenLocked = KeepAwakeAutomationSupport.isScreenLocked(
            sessionDictionary: CGSessionCopyCurrentDictionary() as? [String: Any])
    }

    func execute(_ request: MCPIPCRequest) -> MCPIPCResponse? {
        guard commands.contains(request.command) else { return nil }
        precondition(Thread.isMainThread)
        guard request.minutes == nil, request.value == nil, request.muted == nil,
              request.outputOffset == nil,
              (request.command == "recording_read" || request.offset == nil) else {
            return MCPIPCResponse(ok: false, error: "invalid_arguments")
        }
        if request.command == "recording_start" {
            guard request.id == nil, request.action == nil else { return MCPIPCResponse(ok: false, error: "invalid_arguments") }
            return start(systemAudio: request.systemAudio ?? false, microphone: request.microphone ?? false)
        }
        guard request.systemAudio == nil, request.microphone == nil,
              MCPRecordingPolicy.owned(request.id, owner: ownerID) else {
            return MCPIPCResponse(ok: false, error: "recording_not_owned")
        }
        maintain()
        if request.command != "recording_stop" && !sessionAllowed() {
            return MCPIPCResponse(ok: false, error: "session_inactive")
        }
        if request.command == "recording_status" {
            guard request.action == nil else { return MCPIPCResponse(ok: false, error: "invalid_arguments") }
            return status()
        }
        if request.command == "recording_stop" {
            guard request.action == nil else { return MCPIPCResponse(ok: false, error: "invalid_arguments") }
            stopOwnedCapture()
            return status()
        }
        if request.command == "recording_share" {
            guard request.action == nil else { return MCPIPCResponse(ok: false, error: "invalid_arguments") }
            return requestShare()
        }
        if request.command == "recording_read" {
            guard request.action == nil else { return MCPIPCResponse(ok: false, error: "invalid_arguments") }
            return readExport(offset: request.offset ?? 0)
        }
        guard let shouldPause = MCPRecordingPolicy.pauseAction(request.action) else {
            return MCPIPCResponse(ok: false, error: "invalid_arguments")
        }
        let recorder = ScreenRecorderService.shared
        guard recorder.mcpRecordingID == ownerID, recorder.isRecording else {
            return MCPIPCResponse(ok: false, error: "recording_not_active")
        }
        if recorder.isPaused != shouldPause { recorder.togglePause() }
        guard recorder.isPaused == shouldPause else { return MCPIPCResponse(ok: false, error: "pause_failed") }
        return status()
    }

    private func start(systemAudio: Bool, microphone: Bool) -> MCPIPCResponse {
        guard AppFeature.screenRecorder.isAvailable else { return MCPIPCResponse(ok: false, error: "feature_unavailable") }
        guard sessionAllowed() else { return MCPIPCResponse(ok: false, error: "session_inactive") }
        guard CGPreflightScreenCaptureAccess(), Permissions.shared.screenRecording else { return MCPIPCResponse(ok: false, error: "screen_recording_permission_required") }
        guard AXIsProcessTrusted(), Permissions.shared.accessibility else { return MCPIPCResponse(ok: false, error: "accessibility_permission_required") }
        guard selection == nil, !ScreenshotSelectionController.isSessionOnScreen,
              !ScreenRecorderService.shared.hasActiveCapture else { return MCPIPCResponse(ok: false, error: "capture_busy") }

        clearExport(state: "not_exported")
        let id = UUID()
        let audio = RecorderSelectionAudioOptions(systemAudio: systemAudio, microphone: microphone)
        let options = ScreenCaptureSelectionOptions(availableTools: [.recording], selectedTool: .recording,
                                                    showsCaptureMenu: true, recorderAudio: audio)
        let controller = ScreenshotSelectionController(
            freeze: false, includePointer: false, showLastRegion: false,
            hideVorssaintWindows: true,
            protectedWindowIDs: {
                var windows: Set<CGWindowID> = []
                if AppFeature.screenshot.isAvailable {
                    windows.formUnion(ScreenshotService.shared.protectedWindowIDsForCapture(honoursVisibilityPreference: false))
                }
                if NotchSupport.isEnabled() { windows.formUnion(NotchService.shared.protectedWindowIDs) }
                return windows
            },
            purpose: FeatureStrings.screenshot(L10n.shared.language).screenCaptureTitle,
            mode: .geometry, screenCaptureOptions: options)
        ownerID = id
        selection = controller
        self.options = options
        selectedSystemAudio = systemAudio
        selectedMicrophone = microphone
        phase = "selecting"
        installTimer()
        controller.begin { [weak self, weak controller] outcome in
            guard let self, let controller, self.selection === controller, self.ownerID == id else { return }
            self.selection = nil
            self.options = nil
            guard self.accessAllowed(), self.sessionAllowed(),
                  CGPreflightScreenCaptureAccess(), AXIsProcessTrusted() else { self.phase = "cancelled"; return }
            switch outcome {
            case .region(let region):
                self.selectedSystemAudio = audio.systemAudio
                self.selectedMicrophone = audio.microphone
                // Do not request a new TCC permission on behalf of the agent.
                guard !audio.microphone || Permissions.shared.microphone == .granted else {
                    self.phase = "microphone_permission_required"; return
                }
                guard !ScreenRecorderService.shared.hasActiveCapture,
                      ScreenRecorderService.shared.record(region, audioOptions: audio, mcpOwnerID: id) else {
                    self.phase = "failed"; return
                }
                self.phase = "preparing"
            case .cancelled: self.phase = "cancelled"
            default: self.phase = "failed"
            }
        }
        return status()
    }

    private func accessAllowed() -> Bool {
        let defaults = UserDefaults.standard
        return defaults.bool(forKey: DefaultsKey.mcpEnabled)
            && defaults.bool(forKey: DefaultsKey.mcpCaptureEnabled)
            && defaults.bool(forKey: DefaultsKey.mcpRecordingEnabled)
            && AppFeature.screenRecorder.isAvailable
    }

    private func contentAllowed() -> Bool {
        accessAllowed() && sessionAllowed()
            && UserDefaults.standard.bool(forKey: DefaultsKey.mcpCaptureContentEnabled)
            && CGPreflightScreenCaptureAccess()
    }

    private func sessionAllowed() -> Bool {
        SessionActivity.shared.isActive && !screenLocked
            && !KeepAwakeAutomationSupport.isScreenLocked(
                sessionDictionary: CGSessionCopyCurrentDictionary() as? [String: Any])
    }

    /// Called whenever MCP permissions change. Never stops a recording made
    /// through another app surface, even if it is currently active.
    func syncWithPermissions() {
        precondition(Thread.isMainThread)
        if !accessAllowed() { stopOwnedCapture() }
        if !contentAllowed() { clearExport(state: "not_exported") }
    }

    func stopOwnedCapture() {
        precondition(Thread.isMainThread)
        if let controller = selection {
            selection = nil
            options = nil
            phase = "cancelled"
            controller.cancel()
        }
        if let id = ownerID {
            let recorder = ScreenRecorderService.shared
            if recorder.mcpRecordingID == id, recorder.hasActiveCapture {
                _ = recorder.stopOrCancelActiveCapture()
            }
        }
    }

    /// Called only with the exact destination of this recording's completed
    /// user export (or the app's configured direct-save), never with an IPC path.
    func recordingDidExport(id: UUID, url: URL) {
        precondition(Thread.isMainThread)
        guard ownerID == id, contentAllowed(), url.isFileURL else { return }
        clearExport(state: "not_exported")
        guard let mime = MCPRecordingPolicy.mime(forExtension: url.pathExtension) else { exportState = "unsupported_export"; return }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { exportState = "export_unavailable"; return }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size > 0 else {
            close(fd); exportState = "export_unavailable"; return
        }
        guard MCPRecordingPolicy.validSize(info.st_size) else { close(fd); exportState = "export_too_large"; return }
        exportFD = fd
        exportSize = info.st_size
        exportModificationSeconds = info.st_mtimespec.tv_sec
        exportModificationNanos = info.st_mtimespec.tv_nsec
        exportMIME = mime
        exportState = "available_for_approval"
        exportExpiry = Date().addingTimeInterval(MCPRecordingPolicy.lifetime)
        installTimer()
    }

    func recordingDidFinish(id: UUID, outcome: String) {
        precondition(Thread.isMainThread)
        if ownerID == id { phase = outcome }
    }

    private func requestShare() -> MCPIPCResponse {
        guard contentAllowed() else { return MCPIPCResponse(ok: false, error: "capture_content_disabled") }
        guard exportFD >= 0, exportState == "available_for_approval" else {
            return MCPIPCResponse(ok: false, error: "export_not_available")
        }
        exportState = "awaiting_approval"
        let id = ownerID
        // A modal dialog cannot hold the short IPC request open.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.ownerID == id, self.exportState == "awaiting_approval", self.contentAllowed() else { return }
            let alert = NSAlert()
            let strings = self.approvalStrings
            alert.messageText = strings.title
            alert.informativeText = strings.message
            alert.addButton(withTitle: strings.allow)
            alert.addButton(withTitle: strings.deny)
            self.approval = alert
            NSApp.activate(ignoringOtherApps: true)
            let answer = alert.runModal()
            alert.window.orderOut(nil)
            self.approval = nil
            guard self.ownerID == id, self.exportState == "awaiting_approval" else { return }
            guard answer == .alertFirstButtonReturn, self.contentAllowed(), self.exportFD >= 0,
                  self.exportExpiry.map({ $0 > Date() }) == true else {
                self.clearExport(state: "denied"); return
            }
            self.exportState = "ready"
            self.exportExpiry = Date().addingTimeInterval(MCPRecordingPolicy.lifetime)
        }
        return status()
    }

    private func readExport(offset: Int) -> MCPIPCResponse {
        guard contentAllowed() else { clearExport(state: "not_exported"); return MCPIPCResponse(ok: false, error: "capture_content_disabled") }
        guard exportFD >= 0, exportState == "ready" else { return MCPIPCResponse(ok: false, error: "export_not_ready") }
        guard MCPRecordingPolicy.validOffset(offset, next: exportNextOffset, size: exportSize) else {
            return MCPIPCResponse(ok: false, error: "invalid_offset")
        }
        var info = stat()
        guard fstat(exportFD, &info) == 0, info.st_size == exportSize,
              info.st_mtimespec.tv_sec == exportModificationSeconds,
              info.st_mtimespec.tv_nsec == exportModificationNanos else {
            clearExport(state: "export_changed"); return MCPIPCResponse(ok: false, error: "export_changed")
        }
        let count = min(MCPRecordingPolicy.chunkBytes, Int(exportSize) - offset)
        var bytes = [UInt8](repeating: 0, count: count)
        let readCount = bytes.withUnsafeMutableBytes { pread(exportFD, $0.baseAddress, count, off_t(offset)) }
        guard readCount == count, fstat(exportFD, &info) == 0, info.st_size == exportSize,
              info.st_mtimespec.tv_sec == exportModificationSeconds,
              info.st_mtimespec.tv_nsec == exportModificationNanos else {
            clearExport(state: "export_changed"); return MCPIPCResponse(ok: false, error: "export_changed")
        }
        let next = offset + count
        let done = Int64(next) == exportSize
        let value: [String: Any] = ["id": ownerID!.uuidString, "mime_type": exportMIME,
            "offset": offset, "total_bytes": exportSize, "data_base64": Data(bytes).base64EncodedString(),
            "next_offset": done ? NSNull() : next as Any, "complete": done]
        let response = encode(value)
        if done { clearExport(state: "consumed") } else { exportNextOffset = next }
        return response
    }

    private func clearExport(state: String) {
        if let approval, NSApp.modalWindow === approval.window { NSApp.stopModal(withCode: .abort) }
        if exportFD >= 0 { close(exportFD); exportFD = -1 }
        exportSize = 0; exportNextOffset = 0; exportExpiry = nil; exportState = state
    }

    private func installTimer() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.maintain() }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        // The expiry and permission checks must also run while the approval
        // alert is running its nested modal event loop.
        RunLoop.main.add(timer, forMode: .modalPanel)
    }

    private func maintain() {
        if !accessAllowed() || !sessionAllowed() || !AXIsProcessTrusted()
            || !CGPreflightScreenCaptureAccess() { stopOwnedCapture() }
        expireExportIfNeeded()
        if selection == nil, exportFD < 0, approval == nil,
           ownerID.map({ ScreenRecorderService.shared.mcpRecordingID != $0
               || !ScreenRecorderService.shared.hasActiveCapture }) ?? true {
            timer?.invalidate()
            timer = nil
        }
    }

    private func expireExportIfNeeded() {
        if !contentAllowed() || (exportExpiry.map { $0 <= Date() } ?? false) {
            clearExport(state: "not_exported")
        }
    }

    private var approvalStrings: (title: String, message: String, allow: String, deny: String) {
        switch L10n.shared.language {
        case .enUS: return ("Share recording with the agent?", "The saved screen recording will be sent to the MCP client and may contain private information. The client may send it to an AI model.", "Share", "Cancel")
        case .ru: return ("Передать запись агенту?", "Сохранённая запись экрана будет передана MCP-клиенту и может содержать личные данные. Клиент может отправить её модели ИИ.", "Передать", "Отмена")
        case .uk: return ("Передати запис агенту?", "Збережений запис екрана буде передано MCP-клієнту та може містити особисті дані. Клієнт може надіслати його моделі ШІ.", "Передати", "Скасувати")
        case .ptBR: return ("Compartilhar gravação com o agente?", "A gravação salva será enviada ao cliente MCP e pode conter dados privados. O cliente pode enviá-la a um modelo de IA.", "Compartilhar", "Cancelar")
        case .tr: return ("Kayıt ajanla paylaşılsın mı?", "Kaydedilen ekran görüntüsü MCP istemcisine gönderilir ve özel bilgiler içerebilir. İstemci bunu bir yapay zekâ modeline gönderebilir.", "Paylaş", "İptal")
        case .es: return ("¿Compartir la grabación con el agente?", "La grabación guardada se enviará al cliente MCP y puede contener datos privados. El cliente puede enviarla a un modelo de IA.", "Compartir", "Cancelar")
        case .sk: return ("Zdieľať záznam s agentom?", "Uložený záznam obrazovky sa odošle klientovi MCP a môže obsahovať súkromné údaje. Klient ho môže odoslať modelu AI.", "Zdieľať", "Zrušiť")
        case .de: return ("Aufnahme mit dem Agenten teilen?", "Die gespeicherte Bildschirmaufnahme wird an den MCP-Client gesendet und kann private Daten enthalten. Der Client kann sie an ein KI-Modell senden.", "Teilen", "Abbrechen")
        case .fr: return ("Partager l’enregistrement avec l’agent ?", "L’enregistrement d’écran sera envoyé au client MCP et peut contenir des données privées. Le client peut l’envoyer à un modèle d’IA.", "Partager", "Annuler")
        case .it: return ("Condividere la registrazione con l’agente?", "La registrazione salvata sarà inviata al client MCP e può contenere dati privati. Il client può inviarla a un modello IA.", "Condividi", "Annulla")
        case .ja: return ("録画をエージェントと共有しますか？", "保存した画面録画が MCP クライアントに送信されます。個人情報が含まれる場合があり、クライアントが AI モデルに送信する可能性があります。", "共有", "キャンセル")
        case .ko: return ("녹화를 에이전트와 공유할까요?", "저장된 화면 녹화가 MCP 클라이언트로 전송되며 개인 정보가 포함될 수 있습니다. 클라이언트가 이를 AI 모델에 전송할 수 있습니다.", "공유", "취소")
        case .zhHans: return ("与智能体分享录屏？", "保存的录屏将发送给 MCP 客户端，可能包含私人信息。客户端可能将其发送给 AI 模型。", "分享", "取消")
        case .zhTW: return ("與代理程式分享螢幕錄影？", "儲存的螢幕錄影會傳送給 MCP 用戶端，可能包含私人資訊。用戶端可能將其傳送給 AI 模型。", "分享", "取消")
        case .zhHK: return ("與代理程式分享螢幕錄影？", "儲存的螢幕錄影會傳送給 MCP 用戶端，可能包含私人資訊。用戶端可能將其傳送給 AI 模型。", "分享", "取消")
        }
    }

    private func status() -> MCPIPCResponse {
        let recorder = ScreenRecorderService.shared
        var state = phase
        if ownerID != nil, recorder.mcpRecordingID == ownerID {
            if recorder.mcpIsFinishing { state = "finishing" }
            else if recorder.isRecording { state = recorder.isPaused ? "paused" : "recording" }
            else if recorder.hasActiveCapture { state = "preparing" }
            else if let outcome = recorder.mcpOutcome { state = outcome }
        }
        let object: [String: Any] = [
            "request_id": ownerID?.uuidString as Any? ?? NSNull(), "state": state,
            "elapsed_seconds": recorder.mcpRecordingID == ownerID ? recorder.elapsedSeconds : 0,
            "selected_system_audio": selectedSystemAudio, "selected_microphone": selectedMicrophone,
            "export_state": exportState, "export_bytes": exportFD >= 0 ? exportSize as Any : NSNull(),
            "export_mime_type": exportFD >= 0 ? exportMIME as Any : NSNull()
        ]
        return encode(object)
    }

    private func encode(_ object: [String: Any]) -> MCPIPCResponse {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let value = String(data: data, encoding: .utf8) else {
            return MCPIPCResponse(ok: false, error: "serialization_failed")
        }
        return MCPIPCResponse(ok: true, payload: value)
    }
}
