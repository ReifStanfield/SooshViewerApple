import Foundation

/// One cut of the upstream transport stream: a complete MPEG-TS segment that
/// can be loaded on its own.
///
/// "On its own" is the whole requirement, and it is why `TSSegmenter` caches the
/// PAT and PMT rather than just forwarding them. A decoder handed segment 47
/// with no program tables has no idea which PID carries video.
struct TSSegment: Sendable, Equatable {
    /// Media sequence number. Monotonic for the life of a session, never reused
    /// — HLS clients treat a repeated sequence number as the same segment.
    let index: Int

    let data: Data

    /// Wall-clock length, derived from the PCR delta across the segment.
    let duration: TimeInterval

    /// True when the upstream connection was re-established before this
    /// segment, so the playlist needs an `EXT-X-DISCONTINUITY` ahead of it.
    let isDiscontinuous: Bool
}

/// Splits a raw MPEG-TS byte stream into HLS segments **without decoding it.**
///
/// This is the piece that was actually missing. AVFoundation has always been
/// able to decode MPEG-TS — it is HLS's original segment container, and these
/// streams are ordinary H.264 High + AAC-LC. What it cannot consume is
/// Dispatcharr's `/proxy/ts/stream/`: an endless body with no duration, no index
/// and no segment boundaries, which it probes at length and often abandons.
///
/// So the job here is framing, not decoding. Find the boundaries AVFoundation
/// needs, hand it the same bytes on the other side, and let it do the demuxing
/// and decoding it was always willing to do. That is why this file has no
/// dependency heavier than `Foundation`, and why the app no longer needs
/// FFmpeg — see the ledger in `project.yml` for what that dependency cost.
///
/// **Everything below is header parsing.** ISO/IEC 13818-1: 188-byte packets,
/// a 4-byte header, an optional adaptation field. The elementary streams are
/// never looked at, let alone decoded.
struct TSSegmenter {
    /// MPEG-TS packet size. The 192-byte (M2TS) and 204-byte (DVB, with
    /// Reed-Solomon) variants exist but are not what an HTTP IPTV proxy serves.
    static let packetSize = 188

    static let syncByte: UInt8 = 0x47

    /// Shortest segment we will cut.
    ///
    /// A segment must begin at a random-access point, so the real floor is the
    /// GOP length — measured at ~2s on this server. Setting this below the GOP
    /// does nothing; setting it above merges GOPs and raises join latency,
    /// because a live client starts three target durations back from the end.
    var minSegmentDuration: TimeInterval = 1.5

    /// Longest we will wait for a random-access point before cutting anyway.
    ///
    /// **This is a safety valve, not a target.** A stream that never sets
    /// `random_access_indicator` would otherwise grow one segment forever until
    /// the process ran out of memory. Cutting mid-GOP produces a segment that
    /// does not start on a keyframe, which a decoder recovers from with a brief
    /// artefact — strictly better than unbounded growth.
    var maxSegmentDuration: TimeInterval = 8.0

    // MARK: - Stream tables

    /// Latest PAT packet seen, verbatim, to head every segment.
    private var patPacket: [UInt8]?

    /// Latest PMT packet seen, verbatim, to head every segment.
    private var pmtPacket: [UInt8]?

    private var pmtPID: Int?
    private var videoPID: Int?
    private var pcrPID: Int?

    // MARK: - Cut state

    /// Bytes that arrived mid-packet and are waiting for the rest of theirs.
    private var carry: [UInt8] = []

    /// The segment under construction, PAT and PMT already at its head.
    private var pending: [UInt8] = []

    /// True when `pending` holds only the cached tables and no media yet.
    private var pendingIsEmpty = true

    private var segmentStartPCR: TimeInterval?
    private var lastPCR: TimeInterval?

    private var nextIndex = 0
    private var pendingDiscontinuity = false

    /// Whether a random-access point has been seen since the stream opened.
    ///
    /// **Nothing is kept before the first one.** We join the upstream mid-GOP —
    /// the proxy hands us whatever is going out at the moment we connect — so
    /// the opening bytes are the tail of a picture whose keyframe we never saw.
    /// Keeping them makes segment 0 the one segment in the session that cannot
    /// decode standalone, which is the segment every client loads first.
    private var sawFirstRandomAccessPoint = false

    /// True once a PAT *and* a PMT have been seen, which is the point from which
    /// a segment can be made self-contained.
    var hasProgramTables: Bool { patPacket != nil && pmtPacket != nil }

    init() {}

    // MARK: - Feeding

    /// Marks the stream as having been re-established.
    ///
    /// The next segment emitted carries `isDiscontinuous`, and the parser drops
    /// any half-packet from the old connection — the two byte streams do not
    /// splice, and a straddling packet would be garbage in the middle of an
    /// otherwise valid segment.
    mutating func noteReconnect() {
        carry.removeAll(keepingCapacity: true)
        pending.removeAll(keepingCapacity: true)
        pendingIsEmpty = true
        pendingDiscontinuity = true
        // The reconnect drops us mid-picture again, exactly as the first connect
        // did, so the same rule applies: wait for a keyframe before keeping bytes.
        sawFirstRandomAccessPoint = false
        // The old connection's PCR has no relationship to the new one's.
        segmentStartPCR = nil
        lastPCR = nil
    }

    /// Feeds upstream bytes in and returns whatever segments they completed.
    ///
    /// Returns an empty array most of the time: at a ~2s GOP a segment closes
    /// roughly once per 2s of stream, and this is called per socket read.
    mutating func append(_ bytes: Data) -> [TSSegment] {
        carry.append(contentsOf: bytes)

        var out: [TSSegment] = []
        var cursor = 0

        while carry.count - cursor >= Self.packetSize {
            // Resynchronise if we are not on a sync byte. A well-formed stream
            // never needs this; a proxy that dropped bytes mid-flight does, and
            // without it every subsequent packet parses as noise.
            guard carry[cursor] == Self.syncByte else {
                cursor += 1
                continue
            }

            let packet = Array(carry[cursor ..< cursor + Self.packetSize])
            cursor += Self.packetSize

            if let segment = consume(packet) {
                out.append(segment)
            }
        }

        if cursor > 0 {
            carry.removeFirst(cursor)
        }
        return out
    }

    /// Closes the current segment early, if it holds anything.
    ///
    /// Used at shutdown so the tail is not silently dropped.
    mutating func flush() -> TSSegment? {
        finishSegment()
    }

    // MARK: - One packet

    private mutating func consume(_ packet: [UInt8]) -> TSSegment? {
        let pid = Int(packet[1] & 0x1F) << 8 | Int(packet[2])
        let payloadUnitStart = packet[1] & 0x40 != 0
        let adaptationControl = (packet[3] >> 4) & 0x3

        // Where the payload begins, past any adaptation field.
        var payloadOffset = 4
        if adaptationControl & 0x2 != 0 {
            let adaptationLength = Int(packet[4])
            payloadOffset += 1 + adaptationLength
            if adaptationLength > 0 {
                readPCRIfPresent(packet)
            }
        }
        let hasPayload = adaptationControl & 0x1 != 0

        // Program tables. Cached verbatim so each segment can be headed with
        // them; parsed so we know which PID to cut on.
        if pid == 0, hasPayload, payloadUnitStart {
            patPacket = packet
            parsePAT(packet, payloadOffset: payloadOffset)
        } else if let pmtPID, pid == pmtPID, hasPayload, payloadUnitStart {
            pmtPacket = packet
            parsePMT(packet, payloadOffset: payloadOffset)
        }

        // Nothing can be segmented until a segment can be made self-contained.
        guard hasProgramTables else { return nil }

        // Discard the partial picture we joined mid-way through.
        if !sawFirstRandomAccessPoint {
            guard isRandomAccessPoint(pid: pid, payloadUnitStart: payloadUnitStart, packet: packet, adaptationControl: adaptationControl) else {
                return nil
            }
            sawFirstRandomAccessPoint = true
        }

        var finished: TSSegment?

        if shouldCut(pid: pid, payloadUnitStart: payloadUnitStart, packet: packet, adaptationControl: adaptationControl) {
            finished = finishSegment()
        }

        if pendingIsEmpty {
            startSegment()
        }

        pending.append(contentsOf: packet)
        // The tables themselves do not make a segment worth emitting — a
        // segment of nothing but PAT and PMT has no media in it.
        if pid != 0, pid != pmtPID {
            pendingIsEmpty = false
        }

        return finished
    }

    /// Whether this packet is a legal and desirable place to start a new segment.
    private func shouldCut(
        pid: Int,
        payloadUnitStart: Bool,
        packet: [UInt8],
        adaptationControl: UInt8
    ) -> Bool {
        guard !pendingIsEmpty, let videoPID, pid == videoPID, payloadUnitStart else {
            return false
        }
        let elapsed = pendingDuration

        // The safety valve: cut at any video access-unit start once the segment
        // has run long. See `maxSegmentDuration`.
        if elapsed >= maxSegmentDuration { return true }
        guard elapsed >= minSegmentDuration else { return false }

        // The normal path: cut only at a random-access point, so the segment
        // opens on a keyframe and decodes standalone.
        return isRandomAccessPoint(
            pid: pid,
            payloadUnitStart: payloadUnitStart,
            packet: packet,
            adaptationControl: adaptationControl
        )
    }

    /// Whether this packet begins a video access unit the decoder can enter on.
    ///
    /// `random_access_indicator` is the stream's own declaration of that, which
    /// is why nothing here parses NAL units: the muxer already answered the
    /// question, one bit in the adaptation field.
    private func isRandomAccessPoint(
        pid: Int,
        payloadUnitStart: Bool,
        packet: [UInt8],
        adaptationControl: UInt8
    ) -> Bool {
        guard let videoPID, pid == videoPID, payloadUnitStart else { return false }
        guard adaptationControl & 0x2 != 0, packet[4] > 0 else { return false }
        return packet[5] & 0x40 != 0
    }

    private var pendingDuration: TimeInterval {
        guard let segmentStartPCR, let lastPCR else { return 0 }
        return pcrDelta(from: segmentStartPCR, to: lastPCR)
    }

    private mutating func startSegment() {
        pending.removeAll(keepingCapacity: true)
        if let patPacket { pending.append(contentsOf: patPacket) }
        if let pmtPacket { pending.append(contentsOf: pmtPacket) }
        segmentStartPCR = lastPCR
    }

    private mutating func finishSegment() -> TSSegment? {
        guard !pendingIsEmpty, !pending.isEmpty else { return nil }

        // Fall back to the nominal length when the stream carries no usable PCR.
        // A wrong-but-plausible EXTINF costs drift; a zero one makes the client
        // treat the playlist as malformed.
        let measured = pendingDuration
        let duration = measured > 0 ? measured : minSegmentDuration

        let segment = TSSegment(
            index: nextIndex,
            data: Data(pending),
            duration: duration,
            isDiscontinuous: pendingDiscontinuity
        )
        nextIndex += 1
        pendingDiscontinuity = false
        pending.removeAll(keepingCapacity: true)
        pendingIsEmpty = true
        return segment
    }

    // MARK: - PCR

    /// PCR base is 33 bits at 90kHz, so it wraps every ~26.5 hours. A live
    /// channel left running will cross that, and an unguarded subtraction turns
    /// one segment's duration hugely negative.
    private static let pcrWrap = TimeInterval(1 << 33) / 90_000.0

    private func pcrDelta(from start: TimeInterval, to end: TimeInterval) -> TimeInterval {
        let raw = end - start
        return raw >= 0 ? raw : raw + Self.pcrWrap
    }

    private mutating func readPCRIfPresent(_ packet: [UInt8]) {
        let pid = Int(packet[1] & 0x1F) << 8 | Int(packet[2])
        guard let pcrPID, pid == pcrPID else { return }
        // Adaptation flags live in byte 5, and PCR occupies bytes 6...11.
        guard packet[4] >= 7, packet[5] & 0x10 != 0 else { return }

        let base = UInt64(packet[6]) << 25
            | UInt64(packet[7]) << 17
            | UInt64(packet[8]) << 9
            | UInt64(packet[9]) << 1
            | UInt64(packet[10]) >> 7
        lastPCR = TimeInterval(base) / 90_000.0
        if segmentStartPCR == nil { segmentStartPCR = lastPCR }
    }

    // MARK: - Section parsing

    /// Start of the PSI section inside a payload-unit-start packet, past the
    /// `pointer_field`.
    private func sectionStart(_ packet: [UInt8], payloadOffset: Int) -> Int? {
        guard payloadOffset < packet.count else { return nil }
        let start = payloadOffset + 1 + Int(packet[payloadOffset])
        return start < packet.count ? start : nil
    }

    private mutating func parsePAT(_ packet: [UInt8], payloadOffset: Int) {
        guard let s = sectionStart(packet, payloadOffset: payloadOffset), s + 11 < packet.count else { return }
        let sectionLength = Int(packet[s + 1] & 0x0F) << 8 | Int(packet[s + 2])
        // Section body runs to the 4-byte CRC.
        let end = min(s + 3 + sectionLength - 4, packet.count)

        var i = s + 8
        while i + 3 < end {
            let programNumber = Int(packet[i]) << 8 | Int(packet[i + 1])
            let pid = Int(packet[i + 2] & 0x1F) << 8 | Int(packet[i + 3])
            // Program 0 is the network PID, not a program map.
            if programNumber != 0 {
                pmtPID = pid
                return
            }
            i += 4
        }
    }

    private mutating func parsePMT(_ packet: [UInt8], payloadOffset: Int) {
        guard let s = sectionStart(packet, payloadOffset: payloadOffset), s + 11 < packet.count else { return }
        let sectionLength = Int(packet[s + 1] & 0x0F) << 8 | Int(packet[s + 2])
        let end = min(s + 3 + sectionLength - 4, packet.count)

        pcrPID = Int(packet[s + 8] & 0x1F) << 8 | Int(packet[s + 9])
        let programInfoLength = Int(packet[s + 10] & 0x0F) << 8 | Int(packet[s + 11])

        var i = s + 12 + programInfoLength
        while i + 4 < end {
            let streamType = packet[i]
            let elementaryPID = Int(packet[i + 1] & 0x1F) << 8 | Int(packet[i + 2])
            let esInfoLength = Int(packet[i + 3] & 0x0F) << 8 | Int(packet[i + 4])

            // 0x1B = H.264, 0x24 = HEVC. Both are what VideoToolbox decodes and
            // both are what these channels carry; anything else is left alone
            // and simply never becomes a cut point.
            if streamType == 0x1B || streamType == 0x24, videoPID == nil {
                videoPID = elementaryPID
            }
            i += 5 + esInfoLength
        }

        // A single-program stream may name the video PID as the PCR PID, which
        // is what this server does. If the PMT gave no usable PCR PID, fall back
        // to the video PID rather than losing all timing.
        if pcrPID == 0x1FFF { pcrPID = videoPID }
    }
}
