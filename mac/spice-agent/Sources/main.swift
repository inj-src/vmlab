// vmlab-spice-agent: a SPICE guest agent for macOS. Shares the clipboard (UTF-8 text, PNG images)
// with the SPICE client and saves files dropped on the viewer window to ~/Desktop.
//
// Threads: Port reads and reassembles messages on its io queue. File-transfer messages go
// from there straight to FileXfer's own queue; everything else goes to the main queue, where the
// clipboard state and all NSPasteboard access live.

import AppKit

let args = CommandLine.arguments.dropFirst()
/// -v: log every message type in and out (debugging only; it is chatty during transfers).
let verbose = args.contains("-v")
/// --drop-dir DIR: where dropped files go (default ~/Desktop).
let dropDir: String = {
    if let i = args.firstIndex(of: "--drop-dir"), args.index(after: i) < args.endIndex { return args[args.index(after: i)] }
    return (NSHomeDirectory() as NSString).appendingPathComponent("Desktop")
}()
/// The socket the client connects to (Port.swift). The host's launcher names the same path.
let socketPath: String = {
    var it = args.makeIterator()
    while let a = it.next() {
        if a == "--drop-dir" { _ = it.next(); continue }
        if !a.hasPrefix("-") { return a }
    }
    return (NSHomeDirectory() as NSString).appendingPathComponent("Library/Caches/vmlab-spice-agent.sock")
}()
let pollInterval: DispatchTimeInterval = .milliseconds(500)
/// Largest message we buffer. Bigger ones (well past any sane clipboard) are skipped.
let maxIncomingMessage = 256 << 20

final class Agent {
    let port: Port
    let reader = ChunkReader(maxMessageSize: maxIncomingMessage)
    let pasteboard = Pasteboard()
    let files: FileXfer

    static let ourCaps = Caps(bits: [
        Cap.clipboardByDemand,
        Cap.guestLineEndLF,
        Cap.maxClipboard,
        Cap.fileXferDetailedErrors,
        Cap.clipboardNoReleaseOnRegrab,
    ])

    // Main-queue state.
    private var clientPresent = false        // a client is connected (any client-port message)
    private var clientCaps = Caps()          // what it announced; empty until its ANNOUNCE arrives
    private var maxClipboard = -1            // from VD_AGENT_MAX_CLIPBOARD; -1 = no limit
    private var pollTimer: DispatchSourceTimer?
    private var lastSeenChange = 0           // pasteboard changeCount already handled
    private var ownChange = -1               // changeCount right after we wrote host data
    private var mouseStateLogged = false
    private var guestOwnsHost = false        // we sent GRAB and the client has not taken over

    // Host -> guest fetch: after a client GRAB we request each type we want, one at a time.
    // The protocol has no request ids: a CLIPBOARD reply matches its REQUEST only by order, and
    // spice-gtk silently drops a request it cannot serve (data over its max-clipboard, an empty
    // clipboard). So at most one REQUEST is ever in flight, and it times out.
    private var fetching = false             // a fetch is current (not abandoned)
    private var fetchQueue: [UInt32] = []    // types of the current fetch still to request
    private var fetchResult = HostClip()
    private var fetchBaseChange = 0          // pasteboard changeCount when the grab arrived
    private var inFlight: UInt32?            // type of the REQUEST awaiting its reply
    private var inFlightCurrent = false      // that reply belongs to the current fetch
    private var inFlightTimer: DispatchSourceTimer?
    private var nextOffer: [UInt32]?         // a GRAB that came while an abandoned request was in flight
    /// Give up on a reply after this long without any bytes from the host.
    static let replyTimeout = 10.0

    init(path: String) {
        port = Port(path: path)
        // One staging directory per socket, so an agent started by hand on another socket (the
        // tests do that) never deletes this one's partial files.
        let stage = "Library/Caches/vmlab-spice-agent/partial/" + (path as NSString).lastPathComponent
        files = FileXfer(directory: dropDir, stageDir: (NSHomeDirectory() as NSString).appendingPathComponent(stage))
        files.sendStatus = { [unowned self] in self.send(MsgType.fileXferStatus, $0) }
        port.onOpen = { [unowned self] in
            self.reader.reset()
            self.files.cleanStage()
            var d = Data()
            d.appendLE(UInt32(1))   // request: ask the client for its capabilities
            Agent.ourCaps.words.forEach { d.appendLE($0) }
            self.port.write(encodeMessage(type: MsgType.announceCapabilities, data: d))
        }
        port.onBytes = { [unowned self] bytes in
            try self.reader.feed(bytes) { msg in
                switch msg.type {
                case MsgType.fileXferStart, MsgType.fileXferData, MsgType.fileXferStatus:
                    // Straight to the files queue: file data never waits behind clipboard work.
                    if verbose { log("<- port \(msg.port) type \(msg.type), \(msg.data.count) B") }
                    if msg.type == MsgType.fileXferStart { self.files.start(msg.data) }
                    else if msg.type == MsgType.fileXferData { self.files.data(msg.data) }
                    else { self.files.clientStatus(msg.data) }
                    return
                case MsgType.clientDisconnected:
                    // A message the client was halfway through sending will never complete.
                    self.reader.assemblers[VDP.clientPort]!.reset()
                    self.files.abortAll()
                default:
                    break
                }
                DispatchQueue.main.async { autoreleasepool { self.handle(msg) } }
            }
        }
        port.onClose = { [unowned self] in
            self.reader.reset()
            self.files.abortAll()
            DispatchQueue.main.async { self.clientGone(reason: "connection closed") }
        }
    }

    func start() { port.start() }

    private func send(_ type: UInt32, _ data: Data) {
        if verbose { log("-> type \(type), \(data.count) B") }
        port.write(encodeMessage(type: type, data: data))
    }

    // MARK: message dispatch (main queue)

    private func handle(_ msg: AgentMessage) {
        if verbose { log("<- port \(msg.port) type \(msg.type), \(msg.data.count) B") }
        // Any message on the client port means a client is there. Its ANNOUNCE_CAPABILITIES is
        // not always first: after an agent restart spice-gtk flushes a queued GRAB before it.
        if msg.port == VDP.clientPort && msg.type != MsgType.clientDisconnected { clientArrived() }
        switch msg.type {
        case MsgType.announceCapabilities: announce(msg.data)
        case MsgType.clientDisconnected: clientGone(reason: "client disconnected")
        case MsgType.maxClipboard:
            var r = ByteReader(msg.data)
            if let v = r.u32() { maxClipboard = Int(Int32(bitPattern: v)); log("client max clipboard: \(maxClipboard)") }
        case MsgType.mouseState:
            // Only sent in agent mouse mode; the domain uses <mouse mode='server'/>. Say so once.
            if !mouseStateLogged { log("received MOUSE_STATE: the domain is in agent mouse mode") }
            mouseStateLogged = true
        case MsgType.clipboardGrab: hostGrab(msg.data)
        case MsgType.clipboardRequest: hostRequest(msg.data)
        case MsgType.clipboard: hostData(msg.data)
        case MsgType.clipboardRelease: hostRelease()
        case MsgType.monitorsConfig, MsgType.displayConfig:
            // Not announced, so a client should not send these; reply so it never waits on us.
            var d = Data()
            d.appendLE(msg.type)
            d.appendLE(UInt32(2))   // VD_AGENT_ERROR
            send(MsgType.reply, d)
        default:
            break
        }
    }

    private func announce(_ data: Data) {
        var r = ByteReader(data)
        guard let request = r.u32() else { return }
        var words: [UInt32] = []
        while let w = r.u32() { words.append(w) }
        let caps = Caps(words: words)
        clientCaps = caps
        files.setClientWantsDetails(caps.has(Cap.fileXferDetailedErrors))
        if request != 0 {
            var d = Data()
            d.appendLE(UInt32(0))
            Agent.ourCaps.words.forEach { d.appendLE($0) }
            send(MsgType.announceCapabilities, d)
        }
        log("client capabilities \(caps)")
        if !caps.has(Cap.clipboardByDemand) {
            log("client lacks clipboard-by-demand; not watching the pasteboard")
            stopPolling()
        }
    }

    private func clientArrived() {
        guard !clientPresent else { return }
        clientPresent = true
        log("client connected")
        // Whatever is on the pasteboard now predates this client; only later copies go over.
        lastSeenChange = pasteboard.changeCount
        startPolling()
    }

    private func clientGone(reason: String) {
        guard clientPresent else { return }
        log("\(reason)")
        clientPresent = false
        clientCaps = Caps()
        maxClipboard = -1
        guestOwnsHost = false
        abandonFetch()
        nextOffer = nil
        clearInFlight()   // the server drops replies to a gone client's requests
        stopPolling()
    }

    // MARK: guest -> host

    private func startPolling() {
        guard pollTimer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .main)
        // Generous leeway lets the kernel batch this wakeup with others.
        t.schedule(deadline: .now() + pollInterval, repeating: pollInterval, leeway: .milliseconds(250))
        t.setEventHandler { [unowned self] in autoreleasepool { self.poll() } }
        t.resume()
        pollTimer = t
    }

    private func stopPolling() {
        pollTimer?.cancel()
        pollTimer = nil
    }

    /// NSPasteboard has no change notification; compare changeCount while a client is connected.
    private func poll() {
        let cc = pasteboard.changeCount
        guard cc != lastSeenChange else { return }
        lastSeenChange = cc
        if cc == ownChange { return }        // our own write of host data: never echo it back
        // The guest copied something while host data was on its way; the guest copy is newer.
        abandonFetch()
        nextOffer = nil
        let types = pasteboard.offerTypes()
        if types.isEmpty {
            if guestOwnsHost {
                send(MsgType.clipboardRelease, Data())
                guestOwnsHost = false
            }
            return
        }
        var d = Data()
        types.forEach { d.appendLE($0) }
        send(MsgType.clipboardGrab, d)
        guestOwnsHost = true
    }

    private func hostRequest(_ data: Data) {
        var r = ByteReader(data)
        guard let type = r.u32() else { return }
        var payload = pasteboard.read(type: type) ?? Data()
        if maxClipboard >= 0 && payload.count > maxClipboard {
            log("clipboard of \(payload.count) bytes exceeds the client's limit of \(maxClipboard); sending nothing")
            payload = Data()
        }
        var d = Data(capacity: 4 + payload.count)
        d.appendLE(type)
        d.append(payload)
        send(MsgType.clipboard, d)
    }

    // MARK: host -> guest

    private func hostGrab(_ data: Data) {
        var r = ByteReader(data)
        var offered: [UInt32] = []
        while let t = r.u32() { offered.append(t) }
        guestOwnsHost = false
        abandonFetch()
        if inFlight != nil {
            // A reply to the older grab is still due; ask for this one once it is in (or timed out).
            nextOffer = offered
            return
        }
        beginFetch(offered)
    }

    private func beginFetch(_ offered: [UInt32]) {
        // Fetch right away (not when the guest pastes): text and the best image type, so both are
        // on the pasteboard the way a native copy would put them.
        var want: [UInt32] = []
        if offered.contains(ClipType.utf8Text) { want.append(ClipType.utf8Text) }
        if let img = [ClipType.png, ClipType.bmp, ClipType.jpg, ClipType.tiff].first(where: offered.contains) {
            want.append(img)
        }
        guard !want.isEmpty else { return }
        fetching = true
        fetchQueue = want
        fetchResult = HostClip()
        fetchBaseChange = pasteboard.changeCount
        requestNext()
    }

    private func requestNext() {
        guard fetching else { return }
        guard !fetchQueue.isEmpty else {
            fetching = false
            finishFetch()
            return
        }
        let t = fetchQueue.removeFirst()
        inFlight = t
        inFlightCurrent = true
        var d = Data()
        d.appendLE(t)
        send(MsgType.clipboardRequest, d)
        armReplyTimer(after: Agent.replyTimeout)
    }

    private func armReplyTimer(after secs: Double) {
        inFlightTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + secs, leeway: .milliseconds(500))
        t.setEventHandler { [unowned self] in self.replyTimerFired() }
        t.resume()
        inFlightTimer = t
    }

    private func replyTimerFired() {
        guard let type = inFlight else { return }
        // A big reply takes a while to arrive; wait as long as bytes keep coming.
        let idle = Double(DispatchTime.now().uptimeNanoseconds - port.lastReadTime.uptimeNanoseconds) / 1e9
        if idle < Agent.replyTimeout {
            armReplyTimer(after: Agent.replyTimeout - idle)
            return
        }
        log("no reply to clipboard request for type \(type) in \(Int(Agent.replyTimeout)) s; going on without it")
        let current = inFlightCurrent
        clearInFlight()
        replyDone(current: current)
    }

    private func hostData(_ data: Data) {
        var r = ByteReader(data)
        guard let type = r.u32() else { return }
        guard let want = inFlight else {
            log("clipboard data (type \(type)) with no request in flight; ignored")
            return
        }
        guard type == want || type == ClipType.none else {
            log("clipboard data of type \(type) while waiting for type \(want) (a late reply?); ignored")
            return
        }
        let current = inFlightCurrent
        clearInFlight()
        let payload = r.rest()
        if current, type != ClipType.none, !payload.isEmpty, let clip = Pasteboard.decode(type: type, data: payload) {
            if let t = clip.text { fetchResult.text = t }
            if let p = clip.png { fetchResult.png = p }
        }
        replyDone(current: current)
    }

    /// The in-flight request was answered or timed out: go on with this fetch, or start the grab
    /// that was waiting for the line to clear.
    private func replyDone(current: Bool) {
        if current {
            requestNext()
        } else if let offer = nextOffer {
            nextOffer = nil
            beginFetch(offer)
        }
    }

    private func finishFetch() {
        let clip = fetchResult
        fetchResult = HostClip()
        guard !clip.isEmpty else { return }
        guard pasteboard.changeCount == fetchBaseChange else { return }   // guest copied meanwhile
        ownChange = pasteboard.write(clip)
        lastSeenChange = ownChange
        log("host clipboard -> pasteboard (text: \(clip.text?.utf8.count ?? 0) B, png: \(clip.png?.count ?? 0) B)")
    }

    private func hostRelease() {
        // The host clipboard owner went away. The copy already on the pasteboard stays usable.
        abandonFetch()
        nextOffer = nil
    }

    /// Drop the current fetch. A request still in flight stays in flight: its reply is discarded.
    private func abandonFetch() {
        fetching = false
        fetchQueue = []
        fetchResult = HostClip()
        inFlightCurrent = false
    }

    private func clearInFlight() {
        inFlight = nil
        inFlightCurrent = false
        inFlightTimer?.cancel()
        inFlightTimer = nil
    }
}

signal(SIGPIPE, SIG_IGN)
log("vmlab-spice-agent starting on \(socketPath); dropped files go to \(dropDir)")
let agent = Agent(path: socketPath)
agent.start()
// The main run loop rather than dispatchMain(): AppKit's pasteboard client talks to the
// pasteboard server through run loop sources, and RunLoop.main.run() also drains the main queue.
RunLoop.main.run()
