// swiftlint:disable no_hardcoded_ui_string
// swiftlint:disable inclusive_language
// swiftlint:disable type_body_length
import SwiftUI
import ADBLXShared

struct DNSProtectionView: View {
    let subscriptionService: SubscriptionService
    @State private var viewModel: DNSProtectionViewModel
    @FocusState private var isInputFocused: Bool
    @AppStorage("hasSeenDNSActivationDisclosure") private var hasSeenDisclosure = false
    @State private var showActivationDisclosure = false
    
    init(
        subscriptionService: SubscriptionService = AppCompositionRoot.makeSubscriptionService(),
        viewModel: DNSProtectionViewModel? = nil
    ) {
        self.subscriptionService = subscriptionService
        let entitlement = (subscriptionService as? EntitlementService) ?? AppCompositionRoot.makeSubscriptionService()
        _viewModel = State(initialValue: viewModel ?? DNSProtectionViewModel(entitlementService: entitlement))
    }
    
    /// Shown whenever Premium access is absent, so a tunnel stopped by entitlement loss is
    /// explained rather than silently off.
    private var premiumRequiredNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("dns.premiumRequired.title")
                .font(.headline)
            Text("dns.premiumRequired.body")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("dns.premiumRequired.button") {
                viewModel.showPaywallSheet = true
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .contain)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if !viewModel.isPremium {
                    premiumRequiredNotice
                }
                masterProtectionCard
                resolverSelectionCard
                allowlistManagerCard
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 20)
        }
        .background(DesignColors.background.ignoresSafeArea())
        .navigationTitle("DNS Protection")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await viewModel.load()
        }
        .sheet(isPresented: $viewModel.showPaywallSheet) {
            NavigationStack {
                PremiumView(viewModel: PremiumViewModel(service: subscriptionService))
            }
        }
        .alert("DNS Protection Error", isPresented: $viewModel.showErrorAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(viewModel.errorMessage ?? "An unexpected error occurred.")
        }
        .alert("Enable DNS Protection", isPresented: $showActivationDisclosure) {
            Button("Enable Protection") {
                hasSeenDisclosure = true
                Task {
                    await viewModel.toggleProtection()
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            if viewModel.resolverOption == .quad9Default {
                Text(
                    "DNS processing happens locally on your device. Allowed DNS queries are sent directly to " +
                    "Quad9 (9.9.9.9 / 2620:fe::fe) by default. You can configure a custom resolver in Settings " +
                    "at any time. ADBLX does not collect or store your browsing or DNS data."
                )
            } else {
                Text(
                    "DNS processing happens locally on your device. Allowed DNS queries are sent directly to " +
                    "your configured resolver (\(viewModel.customIPv4)). ADBLX does not collect or store " +
                    "your browsing or DNS data."
                )
            }
        }
    }
    
    // MARK: - Master Protection Card
    
    private var masterProtectionCard: some View {
        VStack(spacing: 16) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(viewModel.isEnabled
                              ? DesignColors.primary.opacity(0.15)
                              : DesignColors.outlineVariant.opacity(0.3))
                        .frame(width: 48, height: 48)
                    
                    Image(systemName: viewModel.isEnabled ? "lock.shield.fill" : "lock.shield")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(viewModel.isEnabled ? DesignColors.primary : DesignColors.onSurfaceVariant)
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("System-wide DNS Shield")
                        .font(DesignTypography.headlineMedium)
                        .foregroundStyle(DesignColors.onSurface)
                    
                    statusBadge
                }
                
                Spacer()
                
                Toggle("", isOn: Binding(
                    get: { viewModel.isEnabled },
                    set: { newValue in
                        if newValue && !hasSeenDisclosure {
                            showActivationDisclosure = true
                        } else {
                            Task {
                                await viewModel.toggleProtection()
                            }
                        }
                    }
                ))
                .labelsHidden()
                .tint(DesignColors.primary)
                .disabled(viewModel.isProcessing)
            }
            
            Divider()
                .background(DesignColors.outlineVariant)
            
            HStack {
                Image(systemName: "info.circle")
                    .foregroundStyle(DesignColors.onSurfaceVariant)
                Text("Blocks ads, tracking, and telemetry across all installed apps using local DNS filtering.")
                    .font(DesignTypography.bodySmall)
                    .foregroundStyle(DesignColors.onSurfaceVariant)
                Spacer()
            }
        }
        .padding(16)
        .background(DesignColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(DesignColors.outlineVariant, lineWidth: 1)
        )
    }
    
    private var statusBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            
            Text(viewModel.connectionStatus.title)
                .font(DesignTypography.labelCaps)
                .foregroundStyle(statusColor)
        }
    }
    
    private var statusColor: Color {
        switch viewModel.connectionStatus {
        case .connected:
            return DesignColors.primary
        case .connecting, .reasserting:
            return DesignColors.secondary
        case .disconnected, .disconnecting:
            return DesignColors.onSurfaceVariant
        case .vpnConflict:
            return Color.orange
        case .error:
            return Color.red
        }
    }
    
    // MARK: - Resolver Selection Card
    
    private var resolverSelectionCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Upstream Resolver")
                    .font(DesignTypography.headlineMedium)
                    .foregroundStyle(DesignColors.onSurface)
                
                Text("Non-blocked DNS queries are forwarded to your chosen upstream provider.")
                    .font(DesignTypography.bodySmall)
                    .foregroundStyle(DesignColors.onSurfaceVariant)
            }
            
            VStack(spacing: 12) {
                // Quad9 Option
                resolverOptionRow(
                    option: .quad9Default,
                    title: "Quad9 (Default)",
                    subtitle: "9.9.9.9 & 2620:fe::fe — Non-profit foundation (Switzerland) with zero IP logging & malware blocking.",
                    isRecommended: true
                )
                
                // Custom Option
                resolverOptionRow(
                    option: .custom,
                    title: "Custom Resolver",
                    subtitle: "Specify a custom DNS resolver IPv4 / IPv6 address (e.g. Pi-hole, router gateway).",
                    isRecommended: false
                )
            }
            
            if viewModel.resolverOption == .custom {
                customResolverInputs
            }
        }
        .padding(16)
        .background(DesignColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(DesignColors.outlineVariant, lineWidth: 1)
        )
    }
    
    private func resolverOptionRow(
        option: UpstreamResolverOption,
        title: String,
        subtitle: String,
        isRecommended: Bool
    ) -> some View {
        Button {
            viewModel.resolverOption = option
            Task {
                await viewModel.saveResolver()
            }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: viewModel.resolverOption == option ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(viewModel.resolverOption == option ? DesignColors.primary : DesignColors.outline)
                    .font(.system(size: 20))
                    .padding(.top, 2)
                
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(title)
                            .font(DesignTypography.bodyLarge)
                            .foregroundStyle(DesignColors.onSurface)
                        
                        if isRecommended {
                            Text("RECOMMENDED")
                                .font(DesignTypography.labelCaps)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(DesignColors.primary.opacity(0.15))
                                .foregroundStyle(DesignColors.primary)
                                .clipShape(Capsule())
                        }
                    }
                    
                    Text(subtitle)
                        .font(DesignTypography.bodySmall)
                        .foregroundStyle(DesignColors.onSurfaceVariant)
                        .multilineTextAlignment(.leading)
                }
                
                Spacer()
            }
            .padding(12)
            .background(viewModel.resolverOption == option ? DesignColors.primary.opacity(0.05) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(viewModel.resolverOption == option ? DesignColors.primary : DesignColors.outlineVariant, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
    
    private var customResolverInputs: some View {
        VStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("IPv4 Address")
                    .font(DesignTypography.labelCaps)
                    .foregroundStyle(DesignColors.onSurfaceVariant)
                
                TextField("e.g. 192.168.1.1 or 1.1.1.1", text: $viewModel.customIPv4)
                    .textFieldStyle(.plain)
                    .padding(10)
                    .background(DesignColors.background)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(DesignColors.outlineVariant, lineWidth: 1)
                    )
            }
            
            VStack(alignment: .leading, spacing: 6) {
                Text("IPv6 Address (Optional)")
                    .font(DesignTypography.labelCaps)
                    .foregroundStyle(DesignColors.onSurfaceVariant)
                
                TextField("e.g. 2606:4700::1111", text: $viewModel.customIPv6)
                    .textFieldStyle(.plain)
                    .padding(10)
                    .background(DesignColors.background)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(DesignColors.outlineVariant, lineWidth: 1)
                    )
            }
            
            Button("Apply Resolver Changes") {
                Task {
                    await viewModel.saveResolver()
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(DesignColors.primary)
            .padding(.top, 4)
        }
        .padding(.top, 8)
    }
    
    // MARK: - Allowlist Manager Card (FR-08)
    
    private var allowlistManagerCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Domain Allowlist")
                        .font(DesignTypography.headlineMedium)
                        .foregroundStyle(DesignColors.onSurface)
                    
                    Spacer()
                    
                    if viewModel.isPublishingAllowlist {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                
                Text("Domains added here bypass the DNS blocklist without restarting the VPN tunnel.")
                    .font(DesignTypography.bodySmall)
                    .foregroundStyle(DesignColors.onSurfaceVariant)
            }
            
            // Add domain input row
            HStack(spacing: 8) {
                TextField("Enter domain (e.g. example.com)", text: $viewModel.newDomainInput)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .focused($isInputFocused)
                    .padding(10)
                    .background(DesignColors.background)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(DesignColors.outlineVariant, lineWidth: 1)
                    )
                
                Button {
                    Task {
                        await viewModel.addAllowlistDomain()
                    }
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(DesignColors.primary)
                }
                .disabled(viewModel.newDomainInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.isPublishingAllowlist)
            }
            
            if viewModel.allowlistDomains.isEmpty {
                Text("No custom allowlisted domains.")
                    .font(DesignTypography.bodySmall)
                    .foregroundStyle(DesignColors.onSurfaceVariant)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 8) {
                    ForEach(viewModel.allowlistDomains, id: \.self) { domain in
                        HStack {
                            Image(systemName: "checkmark.shield.fill")
                                .foregroundStyle(DesignColors.primary)
                            
                            Text(domain)
                                .font(DesignTypography.bodyLarge)
                                .foregroundStyle(DesignColors.onSurface)
                            
                            Spacer()
                            
                            Button {
                                if let index = viewModel.allowlistDomains.firstIndex(of: domain) {
                                    Task {
                                        await viewModel.removeAllowlistDomain(at: IndexSet(integer: index))
                                    }
                                }
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 14))
                                    .foregroundStyle(Color.red.opacity(0.8))
                            }
                            .disabled(viewModel.isPublishingAllowlist)
                        }
                        .padding(10)
                        .background(DesignColors.background)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
            }
        }
        .padding(16)
        .background(DesignColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(DesignColors.outlineVariant, lineWidth: 1)
        )
    }
}
