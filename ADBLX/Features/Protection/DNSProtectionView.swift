// ADBLX/Features/Protection/DNSProtectionView.swift
import SwiftUI

struct DNSProtectionView: View {
    var body: some View {
        ComingSoonState(
            title: "protection.dns.title",
            message: "protection.dns.message"
        )
        .background(DesignColors.background)
    }
}

#Preview {
    DNSProtectionView()
}
