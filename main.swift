// L42 Config — configuration utility for the Elgin L42PRO / L42PRO FULL
//
// A macOS counterpart to Elgin's Windows-only "L42 Pro Utility". It talks to
// the printer over TCP 9100, reads the live configuration with ^HH, and writes
// settings back with ZPL. Field names follow the Elgin utility so the two can
// be used interchangeably.
//
// Firmware update is deliberately absent: the protocol is proprietary and a
// failed write bricks the printer.

import AppKit

// MARK: - Printer link

/// The L42's network card closes the socket when the client half-closes, so
/// this never calls shutdown(); it writes, then reads until the peer stops.
final class Printer {
    var host = "192.168.15.12"
    var port: UInt16 = 9100

    /// "Cannot reach the printer" and "printer is there but not answering"
    /// are different faults with different fixes — never conflate them.
    enum Failure: Error {
        case unreachable        // no TCP connection
        case noReply            // connected, command accepted, nothing came back
        case oneWay             // USB: commands go out, nothing can come back
        case noQueue            // USB selected but no print queue chosen
    }

    /// How we reach the printer. USB goes through a CUPS queue, which is a
    /// one-way pipe: bytes reach the printer, replies never come back. That
    /// is a limitation of macOS printing, not of the printer.
    enum Link: Int { case ethernet = 0, usb = 1 }
    var link: Link = .ethernet
    var cupsQueue = ""

    /// Run a tool and return its stdout.
    static func run(_ path: String, _ args: [String]) -> String {
        let t = Process(), pipe = Pipe()
        t.executableURL = URL(fileURLWithPath: path)
        t.arguments = args
        t.standardOutput = pipe
        t.standardError = FileHandle.nullDevice
        guard (try? t.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        t.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// The driver options a CUPS queue exposes, parsed from `lpoptions -l`.
    /// Line shape:  Key/Human label: a b *current d
    struct DriverOption {
        let key: String, label: String, choices: [String], current: String
    }
    static func driverOptions(queue: String) -> [DriverOption] {
        guard !queue.isEmpty else { return [] }
        return run("/usr/bin/lpoptions", ["-p", queue, "-l"])
            .split(separator: "\n").compactMap { line in
                let parts = line.split(separator: ":", maxSplits: 1)
                guard parts.count == 2 else { return nil }
                let head = parts[0].split(separator: "/", maxSplits: 1)
                let key = String(head[0])
                let label = head.count > 1 ? String(head[1]) : key
                var choices: [String] = [], current = ""
                for raw in parts[1].split(separator: " ") {
                    if raw.hasPrefix("*") {
                        let v = String(raw.dropFirst()); choices.append(v); current = v
                    } else { choices.append(String(raw)) }
                }
                return choices.isEmpty ? nil
                    : DriverOption(key: key, label: label, choices: choices, current: current)
            }
    }

    /// CUPS destinations, for the USB picker.
    static func queues() -> [String] {
        let t = Process(), pipe = Pipe()
        t.executableURL = URL(fileURLWithPath: "/usr/bin/lpstat")
        t.arguments = ["-a"]
        t.standardOutput = pipe
        t.standardError = FileHandle.nullDevice
        guard (try? t.run()) != nil else { return [] }
        t.waitUntilExit()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return out.split(separator: "\n").compactMap { $0.split(separator: " ").first.map(String.init) }
    }

    /// Push raw bytes through a CUPS queue, bypassing the driver's filters.
    private func sendViaCUPS(_ command: String) throws {
        guard !cupsQueue.isEmpty else { throw Failure.noQueue }
        let t = Process(), stdin = Pipe()
        t.executableURL = URL(fileURLWithPath: "/usr/bin/lp")
        t.arguments = ["-d", cupsQueue, "-o", "raw"]
        t.standardInput = stdin
        t.standardOutput = FileHandle.nullDevice
        t.standardError = FileHandle.nullDevice
        try t.run()
        stdin.fileHandleForWriting.write(Data(command.utf8))
        stdin.fileHandleForWriting.closeFile()
        t.waitUntilExit()
        if t.terminationStatus != 0 { throw Failure.unreachable }
    }

    @discardableResult
    func send(_ command: String, expectReply: Bool = false,
              timeout: TimeInterval = 3.0, tries: Int = 3) throws -> String {
        if link == .usb {
            if expectReply { throw Failure.oneWay }
            try sendViaCUPS(command)
            return ""
        }
        var lastError: Error?
        for attempt in 0..<tries {
            do {
                let sock = try RawSocket(host: host, port: port, timeout: 6)
                defer { sock.close() }
                try sock.write(command)
                guard expectReply else { return "" }
                let reply = sock.readAll(timeout: timeout)
                if !reply.isEmpty { return reply }
            } catch {
                lastError = error
            }
            if attempt < tries - 1 { Thread.sleep(forTimeInterval: 1.5) }
        }
        // Reaching here with expectReply means every attempt connected but
        // the printer stayed silent — almost always a media/ribbon error,
        // which makes the firmware buffer commands instead of answering.
        if expectReply { throw lastError ?? Failure.noReply }
        if let e = lastError { throw e }
        return ""
    }

    func reachable() -> Bool {
        (try? RawSocket(host: host, port: port, timeout: 3)).map { $0.close(); return true } ?? false
    }
}

/// Minimal blocking TCP socket — no framework dependency, no half-close.
final class RawSocket {
    private let fd: Int32

    init(host: String, port: UInt16, timeout: TimeInterval) throws {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM,
                             ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil,
                             ai_addr: nil, ai_next: nil)
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &info) == 0, let ai = info else {
            throw Printer.Failure.unreachable
        }
        defer { freeaddrinfo(info) }
        let s = socket(ai.pointee.ai_family, ai.pointee.ai_socktype, ai.pointee.ai_protocol)
        guard s >= 0 else { throw Printer.Failure.unreachable }
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        guard connect(s, ai.pointee.ai_addr, ai.pointee.ai_addrlen) == 0 else {
            Darwin.close(s)
            throw Printer.Failure.unreachable
        }
        fd = s
    }

    func write(_ text: String) throws {
        let bytes = Array(text.utf8)
        var sent = 0
        while sent < bytes.count {
            let n = bytes.withUnsafeBufferPointer {
                Darwin.send(fd, $0.baseAddress! + sent, bytes.count - sent, 0)
            }
            if n <= 0 { throw Printer.Failure.unreachable }
            sent += n
        }
    }

    func readAll(timeout: TimeInterval) -> String {
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var out = [UInt8]()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = recv(fd, &buf, buf.count, 0)
            if n <= 0 { break }
            out.append(contentsOf: buf[0..<n])
        }
        return String(decoding: out, as: UTF8.self).isEmpty
            ? String(bytes: out, encoding: .isoLatin1) ?? ""
            : String(decoding: out, as: UTF8.self)
    }

    func close() { Darwin.close(fd) }
}

// MARK: - Configuration model

enum PrintMethod: String, CaseIterable {
    case direct, transfer
    var label: String { self == .direct ? "Térmica Direta" : "Transf. Térmica" }
    var zpl: String { self == .direct ? "^MTD" : "^MTT" }
}

enum PrintModeOpt: String, CaseIterable {
    case tear, peel, cutter
    var label: String {
        switch self { case .tear: return "Rasgar"; case .peel: return "Destacar"
                      case .cutter: return "Cortar" }
    }
    var zpl: String {
        switch self { case .tear: return "^MMT"; case .peel: return "^MMP"
                      case .cutter: return "^MMC" }
    }
}

/// Media type is really two settings: ^MN says die-cut vs continuous, and
/// ^JS picks the sensor that detects the gap. PPLZ has no "^MNM" — black
/// mark is die-cut media read by the reflective sensor.
enum MediaType: String, CaseIterable {
    case gap, mark, continuous
    var label: String {
        switch self { case .gap: return "Gap (Transmissivo)"
                      case .mark: return "Tarja Preta (Reflexivo)"
                      case .continuous: return "Contínuo" }
    }
    var zpl: String {
        switch self {
        case .gap:        return "^MNY^JST"
        case .mark:       return "^MNY^JSR"
        case .continuous: return "^MNN"
        }
    }
}

enum YesNo: String, CaseIterable {
    case yes, no
    var label: String { self == .yes ? "Sim" : "Não" }
    var code: String { self == .yes ? "Y" : "N" }
}

/// ^CI symbol sets, as listed in the PPLZ manual.
let SYMBOL_SETS = ["0 — USA", "1 — USA2", "2 — Reino Unido", "3 — Holanda",
                   "4 — Dinamarca/Noruega", "5 — Suécia/Finlândia", "6 — Alemanha",
                   "7 — França 1", "8 — França 2", "9 — Itália", "10 — Espanha",
                   "11 — Misc.", "12 — Japão", "13 — IBM/PC"]

let BAUD_RATES = ["1200", "2400", "4800", "9600", "19200", "38400", "57600", "115200"]

enum StartAction: String, CaseIterable {
    case none, calibrate, feed, length
    var label: String {
        switch self { case .none: return "Nenhuma"; case .calibrate: return "Calibrar"
                      case .feed: return "Alimentar"; case .length: return "Medir Etiqueta" }
    }
    var code: String {
        switch self { case .none: return "N"; case .calibrate: return "C"
                      case .feed: return "F"; case .length: return "L" }
    }
}

struct PrinterConfig {
    var method: PrintMethod = .transfer
    var mode: PrintModeOpt = .tear
    var media: MediaType = .gap
    var labelHeightMM = 150
    var labelWidthMM = 100
    var tearOffDots = 0            // -120 ... 120
    var maxCalibMM = 300
    var powerUp: StartAction = .calibrate
    var headClose: StartAction = .calibrate
    var columnOffsetDots = 0       // -90 ... 90   (left position, ^LS)
    var rowOffsetDots = 0          // -90 ... 90   (label top,     ^LT)
    var darkness = 4               // ~SD   (1..30, permanente)
    /// The speed the printer REPORTS in ^HH. The ^PR command uses a
    /// different scale: measured on an L42PRO FULL, ^PR2 -> reports 04,
    /// ^PR3 -> 05, ^PR4 -> 06, and ^PR5 is rejected outright (falls back to
    /// 04). So the command value is the reported value minus 2, and the
    /// usable reported range is 4..6.
    var speedIPS = 4
    static let SPEED_OFFSET = 2
    static let SPEED_REPORTED = [4, 5, 6]
    var reprintAfterError: YesNo = .yes   // ^JZ
    var mirror: YesNo = .no               // ^PM
    var invert: YesNo = .no               // ^PO  (I = 180°)
    var symbolSet = 0                     // ^CI  0..13
    var baudIndex = 3                     // ^SC  9600
    var stopBits = 1                      // ^SC
    var handshakeHardware = false         // ^SC  X = Xon/Xoff, D = hardware

    // Read-only, straight from the printer
    var firmware = "—"
    var serial = "—"
    var resetCounter = "—"
    var totalCounter = "—"
    var ip = "—"
    var mask = "—"
    var mac = "—"
    var networking = "—"
    var gateway = "—"
    var ramFree = "—"
    var flashFree = "—"
    var headUsage = "—"

    static let dotsPerMM = 8

    /// Field names the printer prints in its ^HH dump. Matched longest-first
    /// so "TOTAL USAGE" wins over "USAGE".
    /// The dump pads keys into a column, but a long value squeezes that
    /// padding down to a SINGLE space (FIRMWARE and RAM do this), so the
    /// key cannot be found by looking for a run of whitespace — it has to be
    /// matched against the known names.
    static let HH_KEYS: [String] = [
        "DARKNESS", "PRINT SPEED", "TEAR OFF", "PRINT MODE", "MEDIA TYPE",
        "SENSOR SELECT", "PRINT METHOD", "PRINT WIDTH", "LABEL LENGTH",
        "MAXIMUM LENGTH", "USB COMM.", "BAUD", "DATA BITS", "PARITY",
        "HOST HANDSHAKE", "PROTOCOL", "ETHERNET IP", "MAC", "MASK", "GATEWAY",
        "NETWORKING", "CONTROL CHAR", "COMMAND CHAR", "DELIMITER CHAR",
        "SIMULATION", "MEDIA POWER UP", "HEAD CLOSE", "BACKFEED", "LABEL TOP",
        "LEFT POSITION", "HEXDUMP MODE", "MODES ENABLED", "RESOLUTION",
        "FIRMWARE", "HARDWARE ID", "CONFIGURATION", "RAM", "ONBOARD FLASH",
        "LAST CLEANED", "HEAD USAGE", "TOTAL USAGE", "RESET CNTR1",
        "SERIAL NUMBER", "EARLY WARNING",
    ].sorted { $0.count > $1.count }

    /// Parse the printer's ^HH configuration dump.
    static func parse(_ dump: String) -> PrinterConfig {
        var c = PrinterConfig()
        var fields: [String: String] = [:]
        for raw in dump.replacingOccurrences(of: "\r", with: "").split(separator: "\n") {
            let line = String(raw).replacingOccurrences(of: "\u{02}", with: "")
                                  .replacingOccurrences(of: "\u{03}", with: "")
            let tail = line.trimmingCharacters(in: .whitespaces)
            guard let key = HH_KEYS.first(where: { tail.hasSuffix($0) }) else { continue }
            fields[key] = String(tail.dropLast(key.count))
                .trimmingCharacters(in: .whitespaces)
        }
        func num(_ key: String) -> Int? {
            guard let v = fields[key] else { return nil }
            let digits = v.replacingOccurrences(of: "+", with: "")
                          .components(separatedBy: CharacterSet(charactersIn: "-0123456789").inverted)
                          .joined()
            return Int(digits)
        }

        if let m = fields["PRINT METHOD"] { c.method = m.contains("DIRECT") ? .direct : .transfer }
        if let m = fields["PRINT MODE"] {
            c.mode = m.contains("PEEL") ? .peel : (m.contains("CUT") ? .cutter : .tear)
        }
        if let m = fields["MEDIA TYPE"] {
            c.media = m.contains("CONT") ? .continuous : (m.contains("MARK") ? .mark : .gap)
        }
        if let v = num("LABEL LENGTH") { c.labelHeightMM = max(1, v / dotsPerMM) }
        if let v = num("PRINT WIDTH")  { c.labelWidthMM  = max(1, v / dotsPerMM) }
        if let v = num("TEAR OFF")     { c.tearOffDots = v }
        if let v = num("LABEL TOP")    { c.rowOffsetDots = v }
        if let v = num("LEFT POSITION"){ c.columnOffsetDots = v }
        if let v = num("DARKNESS")     { c.darkness = v }
        if let v = num("PRINT SPEED")  { c.speedIPS = v }
        func action(_ s: String?) -> StartAction {
            guard let s else { return .none }
            if s.contains("CALIBRATION") { return .calibrate }
            if s.contains("FEED") { return .feed }
            if s.contains("LENGTH") { return .length }
            return .none
        }
        c.powerUp = action(fields["MEDIA POWER UP"])
        c.headClose = action(fields["HEAD CLOSE"])
        c.firmware = fields["FIRMWARE"] ?? "—"
        c.serial = fields["SERIAL NUMBER"] ?? "—"
        c.resetCounter = fields["RESET CNTR1"] ?? "—"
        c.totalCounter = fields["TOTAL USAGE"] ?? "—"
        c.ip = fields["ETHERNET IP"] ?? "—"
        c.mask = fields["MASK"] ?? "—"
        c.mac = fields["MAC"] ?? "—"
        c.networking = fields["NETWORKING"] ?? "—"
        c.gateway = fields["GATEWAY"] ?? fields["DEFAULT GATEWAY"] ?? "—"
        c.ramFree = fields["RAM"] ?? "—"
        c.flashFree = fields["ONBOARD FLASH"] ?? "—"
        c.headUsage = fields["HEAD USAGE"] ?? "—"
        // Sensor select refines the media type read from MEDIA TYPE.
        if let sel = fields["SENSOR SELECT"], c.media != .continuous {
            c.media = sel.uppercased().contains("REFLECT") ? .mark : .gap
        }
        if let v = fields["MEDIA TYPE"], v.uppercased().contains("CONT") { c.media = .continuous }
        return c
    }

    /// The commands that write these settings back to the printer.
    func writeCommands() -> String {
        var zpl = "^XA"
        zpl += method.zpl
        zpl += mode.zpl
        zpl += media.zpl
        zpl += "^LL\(labelHeightMM * Self.dotsPerMM)"
        zpl += "^PW\(labelWidthMM * Self.dotsPerMM)"
        zpl += "^ML\(maxCalibMM * Self.dotsPerMM)"
        zpl += "^LT\(rowOffsetDots)"
        zpl += "^LS\(columnOffsetDots)"
        // Send on the command's scale, not the reported one.
        let reported = max(4, min(6, speedIPS))
        zpl += "^PR\(reported - Self.SPEED_OFFSET)"
        zpl += "^MF\(powerUp.code),\(headClose.code)"
        zpl += "^JZ\(reprintAfterError.code)"
        zpl += "^PM\(mirror.code)"
        zpl += "^PO\(invert == .yes ? "I" : "N")"
        zpl += "^CI\(max(0, min(13, symbolSet)))"
        let baud = BAUD_RATES[max(0, min(BAUD_RATES.count - 1, baudIndex))]
        zpl += "^SC\(baud),8,N,\(stopBits),\(handshakeHardware ? "D" : "X")"
        zpl += "^XZ"
        // Control (~) commands stand outside a label format.
        zpl += String(format: "~SD%02d", max(1, min(30, darkness)))
        let t = max(-120, min(120, tearOffDots))
        zpl += t < 0 ? String(format: "~TA-%03d", -t) : String(format: "~TA%03d", t)
        return zpl
    }
}

// MARK: - Small UI helpers

func label(_ s: String, bold: Bool = false, size: CGFloat = 12) -> NSTextField {
    let t = NSTextField(labelWithString: s)
    t.font = bold ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size)
    return t
}

func field(_ text: String = "", width: CGFloat = 120, editable: Bool = true) -> NSTextField {
    let t = NSTextField(string: text)
    t.isEditable = editable
    t.isSelectable = true
    t.font = .systemFont(ofSize: 12)
    t.widthAnchor.constraint(equalToConstant: width).isActive = true
    if !editable { t.drawsBackground = true; t.backgroundColor = .controlBackgroundColor }
    return t
}

/// An NSTextView used as a scroll view's document needs its frame and text
/// container set up explicitly — left at zero size it renders nothing, which
/// is why the status box and command console came up blank.
func mountTextView(_ tv: NSTextView, in scroll: NSScrollView,
                   width: CGFloat, height: CGFloat, editable: Bool) {
    let frame = NSRect(x: 0, y: 0, width: width, height: height)
    tv.frame = frame
    tv.minSize = NSSize(width: 0, height: 0)
    tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                        height: CGFloat.greatestFiniteMagnitude)
    tv.isVerticallyResizable = true
    tv.isHorizontallyResizable = false
    tv.autoresizingMask = [.width]
    tv.textContainer?.containerSize = NSSize(width: width,
                                             height: CGFloat.greatestFiniteMagnitude)
    tv.textContainer?.widthTracksTextView = true
    tv.isEditable = editable
    tv.isSelectable = true
    scroll.documentView = tv
    scroll.hasVerticalScroller = true
    scroll.borderType = .bezelBorder
    scroll.widthAnchor.constraint(equalToConstant: width).isActive = true
    scroll.heightAnchor.constraint(equalToConstant: height).isActive = true
}

/// Every tab gets the SAME fixed viewport, scrolling internally when its
/// content is taller. Without this each pane sizes to its own content and
/// NSTabView resizes the whole window as you switch tabs.
let PANE_W: CGFloat = 620, PANE_H: CGFloat = 470

func tabPane(_ content: NSView) -> NSScrollView {
    let s = NSScrollView()
    s.hasVerticalScroller = true
    s.drawsBackground = false
    s.borderType = .noBorder
    s.documentView = content
    s.widthAnchor.constraint(equalToConstant: PANE_W).isActive = true
    s.heightAnchor.constraint(equalToConstant: PANE_H).isActive = true
    return s
}

func row(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
    let s = NSStackView(views: views)
    s.orientation = .horizontal
    s.spacing = spacing
    s.alignment = .centerY
    return s
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    let printer = Printer()
    var config = PrinterConfig()
    var window: NSWindow!

    // sidebar
    let interfacePop = NSPopUpButton()
    let queuePop = NSPopUpButton()
    let ipField = field("192.168.15.12", width: 130)
    let ipRow = NSStackView()
    let queueRow = NSStackView()
    let oneWayNote = NSTextField(wrappingLabelWithString: "")
    var statusBtn = NSButton()
    var recvBtn = NSButton()
    let fwField = field("—", width: 150, editable: false)
    let serialField = field("—", width: 150, editable: false)
    let resetCounterField = field("—", width: 70, editable: false)
    let totalCounterField = field("—", width: 70, editable: false)
    let statusView = NSTextView()

    // ajustes
    let methodPop = NSPopUpButton()
    let modePop = NSPopUpButton()
    let mediaPop = NSPopUpButton()
    let heightField = field("150", width: 70)
    let widthField = field("100", width: 70)
    let tearField = field("0", width: 70)
    let calibField = field("300", width: 70)
    let powerPop = NSPopUpButton()
    let headPop = NSPopUpButton()
    let colField = field("0", width: 70)
    let rowField = field("0", width: 70)
    let darkField = field("4", width: 70)
    let speedPop = NSPopUpButton()
    let reprintPop = NSPopUpButton()
    let mirrorPop = NSPopUpButton()
    let invertPop = NSPopUpButton()
    let symbolPop = NSPopUpButton()
    let baudPop = NSPopUpButton()
    let stopPop = NSPopUpButton()
    let flowPop = NSPopUpButton()
    let gwField = field("—", width: 130, editable: false)
    let ramField = field("—", width: 130, editable: false)
    let flashField = field("—", width: 130, editable: false)
    let headUseField = field("—", width: 90, editable: false)

    // ethernet (read-only: changing it over the same link would cut the link)
    let netIP = field("—", width: 130, editable: false)
    let netMask = field("—", width: 130, editable: false)
    let netMAC = field("—", width: 150, editable: false)
    let netMode = field("—", width: 130, editable: false)

    // comandos
    let cmdInput = NSTextView()
    let cmdOutput = NSTextView()

    var tabs: NSTabView!
    let driverQueuePop = NSPopUpButton()
    let driverStack = NSStackView()
    var driverControls: [(key: String, pop: NSPopUpButton)] = []

    func applicationDidFinishLaunching(_ n: Notification) {
        printer.host = UserDefaults.standard.string(forKey: "printerIP") ?? "192.168.15.12"
        ipField.stringValue = printer.host

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 620),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "L42 Config"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 960, height: 620)
        window.contentView = buildRoot()
        window.center()
        window.makeKeyAndOrderFront(nil)
        buildMenu()
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            if self.printer.link == .ethernet { self.receive() }
        }
    }

    // MARK: layout

    func buildRoot() -> NSView {
        let split = row([buildSidebar(), buildTabs()], spacing: 14)
        split.alignment = .top
        split.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 10, right: 14)

        let bottom = buildBottomBar()
        let root = NSStackView(views: [split, NSBox.separator(), bottom])
        root.orientation = .vertical
        root.spacing = 8
        root.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 10, right: 0)
        return root
    }

    func buildSidebar() -> NSView {
        let connect = NSButton(title: "Conectar", target: self, action: #selector(receive))
        connect.controlSize = .small

        interfacePop.addItems(withTitles: ["Ethernet — leitura e escrita",
                                           "USB — somente envio"])
        interfacePop.target = self
        interfacePop.action = #selector(interfaceChanged)
        interfacePop.widthAnchor.constraint(equalToConstant: 250).isActive = true

        queuePop.addItems(withTitles: Printer.queues())
        queuePop.widthAnchor.constraint(equalToConstant: 250).isActive = true

        ipRow.orientation = .horizontal
        ipRow.spacing = 8
        ipRow.addArrangedSubview(label("IP:"))
        ipRow.addArrangedSubview(ipField)

        queueRow.orientation = .horizontal
        queueRow.spacing = 8
        queueRow.addArrangedSubview(label("Fila:"))
        queueRow.addArrangedSubview(queuePop)
        queueRow.isHidden = true

        oneWayNote.stringValue = """
            USB é um caminho de mão única no macOS: os comandos chegam à \
            impressora, mas nenhuma resposta volta. Por isso Receber, Obter \
            Status e as informações da impressora ficam indisponíveis. \
            Enviar e as Funções continuam funcionando normalmente.
            """
        oneWayNote.font = .systemFont(ofSize: 10)
        oneWayNote.textColor = .secondaryLabelColor
        oneWayNote.isHidden = true
        oneWayNote.preferredMaxLayoutWidth = 255

        statusView.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        let scroll = NSScrollView()
        mountTextView(statusView, in: scroll, width: 250, height: 330, editable: false)

        statusBtn = NSButton(title: "Obter Status", target: self, action: #selector(getStatus))

        let v = NSStackView(views: [
            label("Conexão", bold: true),
            interfacePop,
            ipRow,
            queueRow,
            oneWayNote,
            connect,
            NSBox.separator(),
            label("Informações da Impressora", bold: true),
            row([label("Firmware:"), fwField]),
            row([label("Nº de Série:"), serialField]),
            row([label("Contador Zerável:"), resetCounterField, label("m")]),
            row([label("Contador Absoluto:"), totalCounterField, label("m")]),
            NSBox.separator(),
            label("Status da Impressora", bold: true),
            scroll,
            statusBtn,
        ])
        v.orientation = .vertical
        v.spacing = 6
        v.alignment = .leading
        v.widthAnchor.constraint(equalToConstant: 270).isActive = true
        return v
    }

    func buildTabs() -> NSView {
        for (pop, items) in [(methodPop, PrintMethod.allCases.map { $0.label }),
                             (modePop, PrintModeOpt.allCases.map { $0.label }),
                             (mediaPop, MediaType.allCases.map { $0.label }),
                             (powerPop, StartAction.allCases.map { $0.label }),
                             (headPop, StartAction.allCases.map { $0.label })] {
            pop.addItems(withTitles: items)
            pop.widthAnchor.constraint(equalToConstant: 190).isActive = true
        }
        // Only the values this printer actually accepts.
        speedPop.addItems(withTitles: PrinterConfig.SPEED_REPORTED.map(String.init))
        speedPop.widthAnchor.constraint(equalToConstant: 70).isActive = true
        for pop in [reprintPop, mirrorPop, invertPop] {
            pop.addItems(withTitles: YesNo.allCases.map { $0.label })
            pop.widthAnchor.constraint(equalToConstant: 190).isActive = true
        }
        symbolPop.addItems(withTitles: SYMBOL_SETS)
        symbolPop.widthAnchor.constraint(equalToConstant: 190).isActive = true
        baudPop.addItems(withTitles: BAUD_RATES)
        baudPop.widthAnchor.constraint(equalToConstant: 120).isActive = true
        stopPop.addItems(withTitles: ["1", "2"])
        stopPop.widthAnchor.constraint(equalToConstant: 70).isActive = true
        flowPop.addItems(withTitles: ["Xon/Xoff", "Hardware"])
        flowPop.widthAnchor.constraint(equalToConstant: 120).isActive = true

        func line(_ title: String, _ control: NSView, _ hint: String = "") -> NSStackView {
            let l = label(title)
            l.widthAnchor.constraint(equalToConstant: 210).isActive = true
            l.alignment = .right
            var views: [NSView] = [l, control]
            if !hint.isEmpty {
                let h = label(hint, size: 10)
                h.textColor = .secondaryLabelColor
                views.append(h)
            }
            return row(views)
        }

        let comum = NSStackView(views: [
            line("MÉTODO DE IMPRESSÃO:", methodPop),
            line("MODO DE IMPRESSÃO:", modePop),
            line("ALTURA DA ETIQUETA:", heightField, "mm"),
            line("LARGURA DA ETIQUETA:", widthField, "mm"),
            line("TIPO DE ETIQUETA:", mediaPop),
            line("POSIÇÃO RASGAR:", tearField, "-120 até 120 (ptos)"),
            line("COMPR. MÁX. CALIBRAÇÃO:", calibField, "mm"),
            line("AÇÃO AO LIGAR:", powerPop),
            line("AÇÃO AO FECHAR A TAMPA:", headPop),
            line("OFFSET DE COLUNA:", colField, "-90 até 90 (ptos)"),
            line("OFFSET DE LINHA:", rowField, "-90 até 90 (ptos)"),
            line("ESCURECIMENTO:", darkField, "1 até 30 (~SD)"),
            line("VELOCIDADE:", speedPop, "ips — enviado como ^PR(valor-2)"),
            line("REIMPRIMIR APÓS ERRO:", reprintPop, "^JZ"),
            line("ESPELHAR IMAGEM:", mirrorPop, "^PM"),
            line("INVERTER 180°:", invertPop, "^PO"),
            line("CONJUNTO DE CARACTERES:", symbolPop, "^CI"),
        ])
        comum.orientation = .vertical
        comum.spacing = 7
        comum.alignment = .leading
        comum.edgeInsets = NSEdgeInsets(top: 12, left: 8, bottom: 8, right: 8)

        let serial = NSStackView(views: [
            line("VELOCIDADE (BAUD):", baudPop),
            line("BITS DE DADOS:", label("8  (fixo)")),
            line("PARIDADE:", label("Nenhuma  (fixo)")),
            line("BITS DE PARADA:", stopPop),
            line("CONTROLE DE FLUXO:", flowPop),
            label("Enviado como ^SC<baud>,8,N,<parada>,<X|D>.", size: 10),
        ])
        serial.orientation = .vertical
        serial.spacing = 7
        serial.alignment = .leading
        serial.edgeInsets = NSEdgeInsets(top: 12, left: 8, bottom: 8, right: 8)

        let ethernet = NSStackView(views: [
            line("ATRIBUIÇÃO DE IP:", netMode),
            line("ENDEREÇO IP:", netIP),
            line("MÁSCARA DE SUB-REDE:", netMask),
            line("GATEWAY:", gwField),
            line("MAC:", netMAC),
            NSBox.separator(),
            line("MEMÓRIA RAM LIVRE:", ramField),
            line("FLASH LIVRE:", flashField),
            line("USO DA CABEÇA:", headUseField, "m"),
            label("Somente leitura: alterar o IP por esta mesma conexão a derrubaria.\nUse a página web da impressora (http://<ip>) para mudanças de rede.", size: 10),
        ])
        ethernet.orientation = .vertical
        ethernet.spacing = 7
        ethernet.alignment = .leading
        ethernet.edgeInsets = NSEdgeInsets(top: 12, left: 8, bottom: 8, right: 8)

        tabs = NSTabView()
        for (title, view) in [("Comum", comum), ("RS-232", serial), ("Ethernet", ethernet),
                              ("Driver (macOS)", buildDriver()),
                              ("Funções", buildFuncoes()), ("Comandos", buildComandos())] {
            let item = NSTabViewItem()
            item.label = title
            item.view = tabPane(view)
            tabs.addTabViewItem(item)
        }
        return tabs
    }

    func buildDriver() -> NSView {
        driverQueuePop.addItems(withTitles: Printer.queues())
        driverQueuePop.target = self
        driverQueuePop.action = #selector(reloadDriverOptions)
        driverQueuePop.widthAnchor.constraint(equalToConstant: 230).isActive = true

        driverStack.orientation = .vertical
        driverStack.spacing = 6
        driverStack.alignment = .leading

        let note = NSTextField(wrappingLabelWithString: """
            Estes são os padrões do driver no macOS — o que o diálogo de             impressão mostra ao abrir. São por fila e independentes das             configurações gravadas na impressora (aba Comum). Quando um valor             está como "PD" (Printer Default), o driver não envia nada e a             impressora usa o que tem na memória.
            """)
        note.font = .systemFont(ofSize: 10)
        note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = 520

        let saveBtn = NSButton(title: "Salvar Padrões do Driver",
                               target: self, action: #selector(saveDriverDefaults))
        let v = NSStackView(views: [row([label("Fila:"), driverQueuePop]), note,
                                    driverStack, saveBtn])
        v.orientation = .vertical
        v.spacing = 8
        v.alignment = .leading
        v.edgeInsets = NSEdgeInsets(top: 12, left: 10, bottom: 8, right: 8)
        DispatchQueue.main.async { self.reloadDriverOptions() }
        return v
    }

    func buildFuncoes() -> NSView {
        func btn(_ title: String, _ sel: Selector, _ note: String) -> NSStackView {
            let b = NSButton(title: title, target: self, action: sel)
            b.widthAnchor.constraint(equalToConstant: 230).isActive = true
            let n = label(note, size: 10)
            n.textColor = .secondaryLabelColor
            return row([b, n])
        }
        let v = NSStackView(views: [
            btn("Calibrar Sensor de Etiquetas", #selector(doCalibrate), "avança etiquetas (~JC)"),
            btn("Imprimir Etiqueta de Configuração", #selector(doConfigLabel), "usa uma etiqueta (~WC)"),
            btn("Avançar Etiqueta", #selector(doFeed), "^XA^XZ"),
            NSBox.separator(),
            btn("Salvar Configurações na Impressora", #selector(doSave), "grava na memória (^JUS)"),
            btn("Reiniciar Impressora", #selector(doReset), "~JR"),
            NSBox.separator(),
            btn("Recarregar Últimas Salvas", #selector(doRecall), "^JUR"),
            btn("Zerar Contador", #selector(doZeroCounter), "<STX>KGRECORD"),
            NSBox.separator(),
            btn("Entrar em Modo Dump (hex)", #selector(doDumpOn), "~JD — diagnóstico"),
            btn("Sair do Modo Dump", #selector(doDumpOff), "~JE"),
            btn("Restaurar Padrões de Fábrica", #selector(doFactory), "^JUF — pede confirmação"),
        ])
        v.orientation = .vertical
        v.spacing = 9
        v.alignment = .leading
        v.edgeInsets = NSEdgeInsets(top: 14, left: 10, bottom: 8, right: 8)
        return v
    }

    func buildComandos() -> NSView {
        cmdInput.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        cmdInput.string = "^XA^HH^XZ"
        cmdOutput.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        cmdOutput.isEditable = false

        func boxed(_ view: NSTextView, _ h: CGFloat, editable: Bool) -> NSScrollView {
            let s = NSScrollView()
            mountTextView(view, in: s, width: 560, height: h, editable: editable)
            return s
        }
        let sendBtn = NSButton(title: "Enviar", target: self, action: #selector(sendRaw))
        let v = NSStackView(views: [
            label("Comando (ZPL ou <STX>K…):", bold: true),
            boxed(cmdInput, 90, editable: true),
            row([sendBtn, label("respostas aparecem abaixo", size: 10)]),
            label("Resposta:", bold: true),
            boxed(cmdOutput, 210, editable: false),
        ])
        v.orientation = .vertical
        v.spacing = 6
        v.alignment = .leading
        v.edgeInsets = NSEdgeInsets(top: 12, left: 10, bottom: 8, right: 8)
        return v
    }

    func buildBottomBar() -> NSView {
        let open = NSButton(title: "Abrir", target: self, action: #selector(openFile))
        let save = NSButton(title: "Salvar", target: self, action: #selector(saveFile))
        recvBtn = NSButton(title: "Receber", target: self, action: #selector(receive))
        let recv = recvBtn
        let send = NSButton(title: "Enviar", target: self, action: #selector(sendConfig))
        for b in [open, save, recv, send] { b.widthAnchor.constraint(equalToConstant: 92).isActive = true }
        send.keyEquivalent = "\r"

        let left = NSStackView(views: [label("Configurações em Arquivo", size: 10), row([open, save])])
        left.orientation = .vertical; left.spacing = 3; left.alignment = .centerX
        let right = NSStackView(views: [label("Configurações na Impressora", size: 10), row([recv, send])])
        right.orientation = .vertical; right.spacing = 3; right.alignment = .centerX

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let bar = row([left, spacer, right])
        bar.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 20)
        return bar
    }

    func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Sobre o L42 Config",
                                   action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                                   keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Encerrar", action: #selector(NSApplication.terminate(_:)),
                                   keyEquivalent: "q"))
        appItem.submenu = appMenu

        let fileItem = NSMenuItem(); main.addItem(fileItem)
        let fileMenu = NSMenu(title: "Arquivo")
        fileMenu.addItem(NSMenuItem(title: "Abrir…", action: #selector(openFile), keyEquivalent: "o"))
        fileMenu.addItem(NSMenuItem(title: "Salvar…", action: #selector(saveFile), keyEquivalent: "s"))
        fileMenu.addItem(.separator())
        fileMenu.addItem(NSMenuItem(title: "Receber da Impressora", action: #selector(receive), keyEquivalent: "r"))
        fileMenu.addItem(NSMenuItem(title: "Enviar para a Impressora", action: #selector(sendConfig), keyEquivalent: "e"))
        fileItem.submenu = fileMenu

        // Edit menu so copy/paste works in the command console
        let editItem = NSMenuItem(); main.addItem(editItem)
        let editMenu = NSMenu(title: "Editar")
        editMenu.addItem(NSMenuItem(title: "Copiar", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Colar", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Selecionar Tudo", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = editMenu

        NSApp.mainMenu = main
    }
}

extension NSBox {
    static func separator() -> NSBox {
        let b = NSBox(); b.boxType = .separator; return b
    }
}

// MARK: - Actions

extension AppDelegate {

    func log(_ s: String) {
        statusView.string += (statusView.string.isEmpty ? "" : "\n") + s
        statusView.scrollToEndOfDocument(nil)
    }

    @objc func reloadDriverOptions() {
        for v in driverStack.arrangedSubviews {
            driverStack.removeArrangedSubview(v); v.removeFromSuperview()
        }
        driverControls.removeAll()
        let queue = driverQueuePop.titleOfSelectedItem ?? ""
        let opts = Printer.driverOptions(queue: queue)
        guard !opts.isEmpty else {
            driverStack.addArrangedSubview(label("Nenhuma opção encontrada para esta fila."))
            return
        }
        for o in opts {
            let l = label(o.label + ":")
            l.widthAnchor.constraint(equalToConstant: 210).isActive = true
            l.alignment = .right
            let pop = NSPopUpButton()
            pop.addItems(withTitles: o.choices)
            pop.selectItem(withTitle: o.current)
            pop.widthAnchor.constraint(equalToConstant: 250).isActive = true
            driverControls.append((o.key, pop))
            driverStack.addArrangedSubview(row([l, pop]))
        }
    }

    @objc func saveDriverDefaults() {
        let queue = driverQueuePop.titleOfSelectedItem ?? ""
        guard !queue.isEmpty else { return }
        var args = ["-p", queue]
        for (key, pop) in driverControls {
            if let v = pop.titleOfSelectedItem { args += ["-o", "\(key)=\(v)"] }
        }
        _ = Printer.run("/usr/bin/lpoptions", args)
        log("Padrões do driver salvos na fila \(queue).")
        reloadDriverOptions()
    }

    @objc func interfaceChanged() {
        let usb = interfacePop.indexOfSelectedItem == 1
        printer.link = usb ? .usb : .ethernet
        ipRow.isHidden = usb
        queueRow.isHidden = !usb
        oneWayNote.isHidden = !usb
        statusBtn.isEnabled = !usb
        recvBtn.isEnabled = !usb
        connectBtnEnabled(!usb)
        if usb {
            queuePop.removeAllItems()
            queuePop.addItems(withTitles: Printer.queues())
            log("Interface USB: somente envio. Receber e Status indisponíveis.")
        } else {
            log("Interface Ethernet: leitura e escrita.")
        }
        // Values read from a printer no longer apply once we can't read.
        for f in [fwField, serialField, resetCounterField, totalCounterField,
                  netIP, netMask, netMAC, netMode, gwField, ramField, flashField, headUseField] {
            if usb { f.stringValue = "—" }
        }
    }

    func connectBtnEnabled(_ on: Bool) {
        // The "Conectar" button lives in the sidebar stack; find it by title.
        func walk(_ v: NSView) {
            if let b = v as? NSButton, b.title == "Conectar" { b.isEnabled = on }
            v.subviews.forEach(walk)
        }
        if let root = window?.contentView { walk(root) }
    }

    /// Turn a link failure into something that points at the real cause.
    func explain(_ e: Error) -> String {
        if case Printer.Failure.noReply = e {
            return """
                Conectado em \(printer.host):9100, mas a impressora não respondeu.
                Isso normalmente significa erro de mídia — ribbon ou etiquetas \
                acabados, ou tampa aberta. Nesse estado o firmware aceita os \
                comandos e para de responder. Verifique a impressora e tente de novo.
                """
        }
        if case Printer.Failure.oneWay = e {
            return "Conexão USB é somente envio — não é possível ler da impressora."
        }
        if case Printer.Failure.noQueue = e {
            return "Selecione a fila de impressão USB na barra lateral."
        }
        return "Não foi possível conectar em \(printer.host):9100. "
             + "Verifique o IP, o cabo de rede e se a impressora está ligada."
    }

    func syncHost() {
        printer.host = ipField.stringValue.trimmingCharacters(in: .whitespaces)
        printer.cupsQueue = queuePop.titleOfSelectedItem ?? ""
        UserDefaults.standard.set(printer.host, forKey: "printerIP")
    }

    /// Run printer I/O off the main thread; hand the result back on it.
    func background(_ work: @escaping () throws -> String,
                    done: @escaping (Result<String, Error>) -> Void) {
        syncHost()
        DispatchQueue.global().async {
            let r: Result<String, Error>
            do { r = .success(try work()) } catch { r = .failure(error) }
            DispatchQueue.main.async { done(r) }
        }
    }

    func formToConfig() -> PrinterConfig {
        var c = config
        c.method = PrintMethod.allCases[methodPop.indexOfSelectedItem]
        c.mode = PrintModeOpt.allCases[modePop.indexOfSelectedItem]
        c.media = MediaType.allCases[mediaPop.indexOfSelectedItem]
        c.labelHeightMM = Int(heightField.stringValue) ?? c.labelHeightMM
        c.labelWidthMM = Int(widthField.stringValue) ?? c.labelWidthMM
        c.tearOffDots = Int(tearField.stringValue) ?? 0
        c.maxCalibMM = Int(calibField.stringValue) ?? 300
        c.powerUp = StartAction.allCases[powerPop.indexOfSelectedItem]
        c.headClose = StartAction.allCases[headPop.indexOfSelectedItem]
        c.columnOffsetDots = Int(colField.stringValue) ?? 0
        c.rowOffsetDots = Int(rowField.stringValue) ?? 0
        c.darkness = Int(darkField.stringValue) ?? c.darkness
        c.speedIPS = PrinterConfig.SPEED_REPORTED[
            max(0, min(PrinterConfig.SPEED_REPORTED.count - 1, speedPop.indexOfSelectedItem))]
        c.reprintAfterError = YesNo.allCases[reprintPop.indexOfSelectedItem]
        c.mirror = YesNo.allCases[mirrorPop.indexOfSelectedItem]
        c.invert = YesNo.allCases[invertPop.indexOfSelectedItem]
        c.symbolSet = symbolPop.indexOfSelectedItem
        c.baudIndex = baudPop.indexOfSelectedItem
        c.stopBits = stopPop.indexOfSelectedItem + 1
        c.handshakeHardware = flowPop.indexOfSelectedItem == 1
        return c
    }

    func configToForm() {
        methodPop.selectItem(at: PrintMethod.allCases.firstIndex(of: config.method) ?? 1)
        modePop.selectItem(at: PrintModeOpt.allCases.firstIndex(of: config.mode) ?? 0)
        mediaPop.selectItem(at: MediaType.allCases.firstIndex(of: config.media) ?? 0)
        heightField.stringValue = "\(config.labelHeightMM)"
        widthField.stringValue = "\(config.labelWidthMM)"
        tearField.stringValue = "\(config.tearOffDots)"
        calibField.stringValue = "\(config.maxCalibMM)"
        powerPop.selectItem(at: StartAction.allCases.firstIndex(of: config.powerUp) ?? 0)
        headPop.selectItem(at: StartAction.allCases.firstIndex(of: config.headClose) ?? 0)
        colField.stringValue = "\(config.columnOffsetDots)"
        rowField.stringValue = "\(config.rowOffsetDots)"
        darkField.stringValue = "\(config.darkness)"
        speedPop.selectItem(at: PrinterConfig.SPEED_REPORTED.firstIndex(of: config.speedIPS) ?? 0)
        reprintPop.selectItem(at: YesNo.allCases.firstIndex(of: config.reprintAfterError) ?? 0)
        mirrorPop.selectItem(at: YesNo.allCases.firstIndex(of: config.mirror) ?? 1)
        invertPop.selectItem(at: YesNo.allCases.firstIndex(of: config.invert) ?? 1)
        symbolPop.selectItem(at: max(0, min(SYMBOL_SETS.count - 1, config.symbolSet)))
        baudPop.selectItem(at: max(0, min(BAUD_RATES.count - 1, config.baudIndex)))
        stopPop.selectItem(at: config.stopBits == 2 ? 1 : 0)
        flowPop.selectItem(at: config.handshakeHardware ? 1 : 0)
        gwField.stringValue = config.gateway
        ramField.stringValue = config.ramFree
        flashField.stringValue = config.flashFree
        headUseField.stringValue = config.headUsage

        fwField.stringValue = config.firmware
        serialField.stringValue = config.serial
        resetCounterField.stringValue = config.resetCounter
        totalCounterField.stringValue = config.totalCounter
        netIP.stringValue = config.ip
        netMask.stringValue = config.mask
        netMAC.stringValue = config.mac
        netMode.stringValue = config.networking
    }

    // MARK: read / write

    @objc func receive() {
        log("Lendo configuração…")
        background({ try self.printer.send("^XA^HH^XZ", expectReply: true) }) { r in
            switch r {
            case .success(let dump):
                self.config = PrinterConfig.parse(dump)
                self.configToForm()
                self.log("Configuração recebida.")
            case .failure(let e):
                self.log(self.explain(e))
            }
        }
    }

    @objc func sendConfig() {
        let c = formToConfig()
        config = c
        log("Enviando configuração…")
        background({ try self.printer.send(c.writeCommands()); return "" }) { r in
            switch r {
            case .success:
                self.log("Enviado. Use Funções ▸ Salvar Configurações para gravar na memória.")
            case .failure:
                self.log("Falha ao enviar.")
            }
        }
    }

    @objc func getStatus() {
        log("Consultando…")
        background({ try self.printer.send("^XA^HH^XZ", expectReply: true) }) { r in
            switch r {
            case .success(let dump):
                self.statusView.string = dump.replacingOccurrences(of: "\r", with: "")
                self.statusView.scrollToBeginningOfDocument(nil)
            case .failure(let e):
                self.log(self.explain(e))
            }
        }
    }

    // MARK: funções

    func simple(_ cmd: String, _ note: String) {
        log(note + "…")
        background({ try self.printer.send(cmd); return "" }) { r in
            self.log(r.isSuccess ? note + " — enviado." : note + " — falhou.")
        }
    }

    @objc func doCalibrate()   { simple("~JC", "Calibrar sensor") }
    @objc func doConfigLabel() { simple("~WC", "Imprimir etiqueta de configuração") }
    @objc func doFeed()        { simple("^XA^XZ", "Avançar etiqueta") }
    @objc func doSave()        { simple("^XA^JUS^XZ", "Salvar configurações na impressora") }
    @objc func doReset()       { simple("~JR", "Reiniciar impressora") }
    @objc func doZeroCounter() { simple("\u{02}KGRECORD", "Zerar contador") }
    @objc func doRecall()      { simple("^XA^JUR^XZ", "Recarregar últimas salvas") }
    @objc func doDumpOn()      { simple("~JD", "Entrar em modo dump") }
    @objc func doDumpOff()     { simple("~JE", "Sair do modo dump") }

    @objc func doFactory() {
        let a = NSAlert()
        a.messageText = "Restaurar padrões de fábrica?"
        a.informativeText = "Todas as configurações da impressora voltarão ao padrão. "
                          + "Será necessário calibrar o sensor novamente."
        a.addButton(withTitle: "Restaurar")
        a.addButton(withTitle: "Cancelar")
        a.alertStyle = .warning
        guard a.runModal() == .alertFirstButtonReturn else { return }
        simple("^XA^JUF^XZ", "Restaurar padrões de fábrica")
    }

    // MARK: comandos

    @objc func sendRaw() {
        let cmd = cmdInput.string
        guard !cmd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        cmdOutput.string = "enviando…"
        background({ try self.printer.send(cmd, expectReply: true, timeout: 3.0) }) { r in
            switch r {
            case .success(let reply):
                self.cmdOutput.string = reply.isEmpty ? "(sem resposta)"
                                                      : reply.replacingOccurrences(of: "\r", with: "")
            case .failure:
                // Many commands legitimately return nothing; report that plainly.
                self.cmdOutput.string = "(sem resposta — comando pode ter sido aceito)"
            }
        }
    }

    // MARK: arquivo

    @objc func saveFile() {
        let p = NSSavePanel()
        p.nameFieldStringValue = "l42-config.json"
        p.beginSheetModal(for: window) { resp in
            guard resp == .OK, let url = p.url else { return }
            let c = self.formToConfig()
            let obj: [String: Any] = [
                "method": c.method.rawValue, "mode": c.mode.rawValue, "media": c.media.rawValue,
                "labelHeightMM": c.labelHeightMM, "labelWidthMM": c.labelWidthMM,
                "tearOffDots": c.tearOffDots, "maxCalibMM": c.maxCalibMM,
                "powerUp": c.powerUp.rawValue, "headClose": c.headClose.rawValue,
                "columnOffsetDots": c.columnOffsetDots, "rowOffsetDots": c.rowOffsetDots,
                "darkness": c.darkness, "speedIPS": c.speedIPS,
            ]
            if let d = try? JSONSerialization.data(withJSONObject: obj,
                                                   options: [.prettyPrinted, .sortedKeys]) {
                try? d.write(to: url)
                self.log("Configuração salva em \(url.lastPathComponent).")
            }
        }
    }

    @objc func openFile() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.json]
        p.beginSheetModal(for: window) { resp in
            guard resp == .OK, let url = p.url, let d = try? Data(contentsOf: url),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
            var c = self.config
            if let v = o["method"] as? String, let m = PrintMethod(rawValue: v) { c.method = m }
            if let v = o["mode"] as? String, let m = PrintModeOpt(rawValue: v) { c.mode = m }
            if let v = o["media"] as? String, let m = MediaType(rawValue: v) { c.media = m }
            if let v = o["labelHeightMM"] as? Int { c.labelHeightMM = v }
            if let v = o["labelWidthMM"] as? Int { c.labelWidthMM = v }
            if let v = o["tearOffDots"] as? Int { c.tearOffDots = v }
            if let v = o["maxCalibMM"] as? Int { c.maxCalibMM = v }
            if let v = o["powerUp"] as? String, let a = StartAction(rawValue: v) { c.powerUp = a }
            if let v = o["headClose"] as? String, let a = StartAction(rawValue: v) { c.headClose = a }
            if let v = o["columnOffsetDots"] as? Int { c.columnOffsetDots = v }
            if let v = o["rowOffsetDots"] as? Int { c.rowOffsetDots = v }
            if let v = o["darkness"] as? Int { c.darkness = v }
            if let v = o["speedIPS"] as? Int { c.speedIPS = v }
            self.config = c
            self.configToForm()
            self.log("Configuração carregada de \(url.lastPathComponent).")
        }
    }
}

extension Result {
    var isSuccess: Bool { if case .success = self { return true }; return false }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
