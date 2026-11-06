import Foundation

/// Helpers on a bare DNS message (no IP or UDP header): what a TCP client sends, and what the
/// forwarder needs to answer when the upstream can't.
public enum DNSMessage {
    private static let headerLength = 12

    /// Index just past the first question (name, type, class), or nil if there isn't a plain one.
    private static func questionEnd(_ m: [UInt8]) -> Int? {
        guard m.count >= headerLength, (Int(m[4]) << 8 | Int(m[5])) >= 1 else { return nil }
        var i = headerLength
        while i < m.count {
            let len = Int(m[i])
            if len == 0 { return i + 5 <= m.count ? i + 5 : nil }
            if len & 0xC0 != 0 || i + 1 + len > m.count { return nil }   // no compression in a question
            i += 1 + len
        }
        return nil
    }

    /// A response with just the header and the question, for `rcode` (2 = SERVFAIL, 3 = NXDOMAIN).
    /// Nil if `query` has no readable question.
    public static func errorResponse(for query: Data, rcode: UInt8) -> Data? {
        let q = [UInt8](query)
        guard let end = questionEnd(q) else { return nil }
        var r = [UInt8](q[0..<headerLength])
        r[2] = 0x80 | (q[2] & 0x01)          // QR=1, RD copied
        r[3] = 0x80 | (rcode & 0x0F)         // RA=1
        r[4] = 0; r[5] = 1                   // one question
        for i in 6..<headerLength { r[i] = 0 }
        r.append(contentsOf: q[headerLength..<end])
        return Data(r)
    }

    public static func isTruncated(_ response: Data) -> Bool {
        response.count >= 3 && response[response.startIndex + 2] & 0x02 != 0
    }

    /// The response cut down to header and question with TC set, so the client retries over TCP.
    public static func truncated(_ response: Data) -> Data {
        var r = [UInt8](response)
        guard r.count >= headerLength else { return response }
        let end = questionEnd(r)
        r[2] |= 0x02
        for i in 6..<headerLength { r[i] = 0 }
        guard let end else { r[4] = 0; r[5] = 0; return Data(r[0..<headerLength]) }
        return Data(r[0..<end])
    }

    /// How many bytes of answer the client can take over UDP: 512 unless its EDNS0 record says
    /// more, and never above 1232, which fits an IPv6 packet without fragmenting.
    public static func clientUDPLimit(of query: Data) -> Int {
        let q = [UInt8](query)
        guard var i = questionEnd(q) else { return 512 }
        let answers = Int(q[6]) << 8 | Int(q[7]), authority = Int(q[8]) << 8 | Int(q[9])
        var additional = Int(q[10]) << 8 | Int(q[11])
        guard answers == 0, authority == 0 else { return 512 }
        while additional > 0, i + 11 <= q.count {
            guard q[i] == 0 else { return 512 }   // an OPT record's owner is the root
            let type = Int(q[i + 1]) << 8 | Int(q[i + 2])
            let cls = Int(q[i + 3]) << 8 | Int(q[i + 4])
            if type == 41 { return min(max(cls, 512), 1232) }
            let rdlen = Int(q[i + 9]) << 8 | Int(q[i + 10])
            i += 11 + rdlen
            additional -= 1
        }
        return 512
    }

    /// The question's name, lowercased, labels reversed (`ads.example.com` -> `com.example.ads`).
    public static func reversedDomain(of query: Data) -> InlineReversedDomainBuffer? {
        let q = [UInt8](query)
        guard questionEnd(q) != nil else { return nil }
        var labels: [Range<Int>] = []
        var i = headerLength
        while q[i] != 0 {
            let len = Int(q[i])
            labels.append((i + 1)..<(i + 1 + len))
            i += 1 + len
        }
        guard !labels.isEmpty else { return nil }
        var buffer = InlineReversedDomainBuffer()
        for (n, range) in labels.reversed().enumerated() {
            if n > 0, !buffer.append(byte: 46) { return nil }
            for byte in q[range] {
                guard buffer.append(byte: (byte >= 65 && byte <= 90) ? byte + 32 : byte) else { return nil }
            }
        }
        return buffer
    }
}
