// ADBLX/Features/Protection/DNSProtectionView.swift
import SwiftUI

struct DNSProtectionView: View {
    var body: some View {
        ComingSoonState(
            title: "DNS Protection",
            message: "System-wide DNS filtering blocks ads and trackers across every app on your device — entirely on-device, with nothing sent to a server. Available with Premium in a future update."
        )
        .background(DesignColors.background)
    }
}

#Preview {
    DNSProtectionView()
}
