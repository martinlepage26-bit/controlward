import AppKit
import SwiftUI

struct DiscoveryContextPanel: View {
    @EnvironmentObject private var store: AppStore
    @State private var expanded = false
    @State private var reviewEnquiries = false
    @State private var result: String?
    private var context: KairosDiscoveryContext? { store.websiteResearch.kairosContext }
    private var enquiryCount: Int { DiscoveryIntelligence.enquiries(store.leads).count }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("KAIROS targeting and enquiries").font(.headline)
                Text("\(enquiryCount) retained enquiries").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Refresh KAIROS context") {
                    Task {
                        let saved = await store.refreshKairosDiscovery()
                        result = saved ? "Targeting, performance context and enquiries saved." : (store.notice ?? store.latestSyncJob(for: .kairos)?.error)
                    }
                }.disabled(store.isReviewMode || store.busyTargets.contains(.kairos))
                Button("Review enquiry links") { reviewEnquiries = true }.disabled(enquiryCount == 0)
            }
            if let result { Text(result).font(.caption).foregroundStyle(.secondary) }
            DisclosureGroup("Audience, source availability and content experiments", isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 7) {
                    if let context {
                        Text(context.targetingBrief).font(.caption).textSelection(.enabled)
                        Button("Copy targeting brief") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(context.targetingBrief, forType: .string)
                            result = "Targeting brief copied."
                        }
                        if let paused = context.disabledPlatforms {
                            Text(paused.isEmpty ? "KAIROS reports no platform pause. Connected-channel collection still needs its own verification."
                                 : "Enquiry collection paused: " + paused.sorted().joined(separator: ", ") + ". Saved enquiries remain available; an empty inbox does not establish a lack of interest.")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("Collection availability was not reported. An empty inbox is not evidence of low interest.").font(.caption).foregroundStyle(.secondary)
                        }
                        Text("Content performance · \(context.insights.window): \(context.insights.totals.posts) posts, \(context.insights.totals.impressions) impressions, \(context.insights.totals.engagements) engagements.")
                            .font(.caption)
                        ForEach(Array(context.insights.pillars.prefix(5).enumerated()), id: \.offset) { _, pillar in
                            Text("\(pillar.name): \(pillar.posts) posts · average content score \(pillar.avg_score.map { String(format: "%.2f", $0) } ?? "unknown")").font(.caption)
                        }
                        Text("Use these aggregate results to choose topics and segments to test. They do not establish an individual prospect's buying intent. Source: \(context.endpoint)/v1/insights · retrieved \(context.fetchedAt)")
                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    } else {
                        Text("Refresh the existing KAIROS API connection to read its saved audience, positioning, inbox availability and aggregate content results. Fit stays unknown until reviewed. Browser sign-in and the native API connection are separate.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.top, 6)
            }
        }
        .padding(10).background(CRMTheme.steel.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        .sheet(isPresented: $reviewEnquiries) { DiscoveryEnquiryReviewView() }
    }
}

struct DiscoveryAssessmentView: View {
    let attention: DiscoveryAttention
    let review: DiscoveryFitReview?
    var reviewFit: () -> Void
    @State private var sourcesExpanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("Fit · " + attention.fit.label).font(.caption.weight(.semibold))
                Button("Review fit", action: reviewFit).font(.caption)
            }
            Text(attention.fitReason).font(.caption).foregroundStyle(.secondary)
            Text("Interest · " + attention.interestLabel).font(.caption)
            Text("Contactability · " + attention.contactabilityLabel).font(.caption)
            if !attention.business.supportedContacts.isEmpty {
                Text("The route is published on the business website. Delivery and personal-inbox ownership are unknown.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Button(sourcesExpanded ? "Hide assessment sources and reasons" : "Show assessment sources and reasons") {
                sourcesExpanded.toggle()
            }.buttonStyle(.plain).font(.caption)
            if sourcesExpanded {
                if let review {
                    Text("Owner fit review · \(review.reviewedAt) · \(review.reason)").font(.caption).textSelection(.enabled)
                }
                ForEach(attention.enquiries) { enquiry in
                    Text("Incoming enquiry · \(enquiry.sourcePlatform ?? "channel unknown") · \(enquiry.sourceID ?? "") · \(enquiry.sourceUpdatedAt ?? "date unknown")\n\(enquiry.sourceMessage ?? "Incoming text unavailable; current interest is unknown.")")
                        .font(.caption).textSelection(.enabled)
                }
                ForEach(Array(attention.interestReasons.enumerated()), id: \.offset) { _, reason in
                    Text(reason).font(.caption).textSelection(.enabled)
                }
                ForEach(Array(attention.business.supportedContacts.enumerated()), id: \.offset) { _, contact in
                    Text("Published \(contact.kind.rawValue): \(contact.value) · \(contact.evidence.url)\n\(contact.evidence.excerpt)")
                        .font(.caption).textSelection(.enabled)
                }
                Text("\(attention.business.aliases.count) website/map finding(s) grouped by website. Original source identities are retained.")
                    .font(.caption2).foregroundStyle(.secondary)
                ForEach(attention.business.aliases) { source in
                    Text("\(source.sourceID) · \(source.sourceURL) · \(source.capturedAt)").font(.caption2).textSelection(.enabled)
                }
            }
        }
    }
}

struct DiscoveryFitSelection: Identifiable {
    var attention: DiscoveryAttention
    var review: DiscoveryFitReview?
    var strategyRevision: UUID?
    var id: String { attention.id }
}

private struct DiscoveryEnquiryReviewView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var limit = 50
    private var enquiries: [Lead] { DiscoveryIntelligence.enquiries(store.leads) }
    private var businesses: [DiscoveryBusiness] { DiscoveryIntelligence.businesses(store.websiteResearch).filter(\.verifiedWebsite) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("Review enquiry-to-business links").font(.title2.bold()); Spacer(); Button("Done") { dismiss() } }
            Text("A website or mailbox mentioned in an enquiry is a suggestion. Confirm which researched business it concerns. Similar names and social handles alone are not identity evidence. Linking preserves CRM records and outreach history.")
                .font(.caption).foregroundStyle(.secondary)
            if businesses.isEmpty { Text("Research a business website before confirming an association.").foregroundStyle(.secondary) }
            List(Array(enquiries.prefix(limit))) { enquiry in
                DiscoveryEnquiryReviewRow(enquiry: enquiry, businesses: businesses,
                    confirmed: store.websiteResearch.enquiryBusinessLinks?[enquiry.sourceID ?? ""])
            }
            if enquiries.count > limit { Button("Show 50 more enquiries") { limit += 50 } }
        }.padding(20).frame(minWidth: 720, minHeight: 480)
    }
}

private struct DiscoveryEnquiryReviewRow: View {
    @EnvironmentObject private var store: AppStore
    let enquiry: Lead
    let businesses: [DiscoveryBusiness]
    let confirmed: DiscoveryEnquiryLink?
    @State private var selected = ""
    @State private var reason = ""
    @State private var result: String?
    @State private var evidenceExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(enquiry.name).font(.headline)
            Text("\(enquiry.sourcePlatform ?? "Unknown channel") · \(enquiry.sourceID ?? "") · \(enquiry.sourceUpdatedAt ?? "Date unknown")")
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Text(enquiry.sourceMessage ?? "No retained incoming text. Interest remains unknown.").font(.caption).lineLimit(5).textSelection(.enabled)
            Picker("Researched business", selection: $selected) {
                Text("Choose a business").tag("")
                if let key = confirmed?.businessKey, !businesses.contains(where: { $0.id == key }) {
                    Text("Previously linked business needs website research").tag(key)
                }
                ForEach(businesses) { business in
                    Text(business.candidate.name + " · " + (DiscoveryIntelligence.host(business.candidate.website) ?? "Researched website")).tag(business.id)
                }
            }
            if let business = businesses.first(where: { $0.id == selected }), let suggestion = DiscoveryIntelligence.suggestion(enquiry, for: business) {
                Text("Suggestion: " + suggestion).font(.caption).foregroundStyle(.secondary)
            }
            TextField("Why this enquiry belongs to this business (required when there is no source suggestion)", text: $reason, axis: .vertical)
            HStack {
                Button("Confirm association") {
                    result = store.linkDiscoveryEnquiry(sourceID: enquiry.sourceID ?? "", businessKey: selected, reason: reason) ? "Association confirmed." : store.notice
                }.disabled(selected.isEmpty)
                if confirmed?.businessKey != nil {
                    Text("Confirmed link saved").font(.caption).foregroundStyle(CRMTheme.moss)
                    Button("Unlink") {
                        if store.linkDiscoveryEnquiry(sourceID: enquiry.sourceID ?? "", businessKey: nil) { selected = ""; result = "Association removed; enquiry retained." }
                        else { result = store.notice }
                    }
                }
            }
            if let result { Text(result).font(.caption) }
            if let confirmed, let explanation = confirmed.reason {
                Button(evidenceExpanded ? "Hide saved association evidence" : "Show saved association evidence") {
                    evidenceExpanded.toggle()
                }.buttonStyle(.plain).font(.caption)
                .accessibilityLabel((evidenceExpanded ? "Hide" : "Show") + " saved association evidence for " + enquiry.name)
                if evidenceExpanded {
                    Text("\(explanation)\nConfirmed: \(confirmed.confirmedAt)\nIncoming at review: \(confirmed.incomingAt ?? "unknown")\n\(confirmed.incomingExcerpt ?? "No incoming text available")\nBusiness source: \(confirmed.businessSourceURL ?? "unknown")")
                        .font(.caption).textSelection(.enabled)
                }
            }
        }.padding(.vertical, 7)
        .onAppear {
            if let key = confirmed?.businessKey { selected = key; reason = confirmed?.reason ?? "" }
            else {
                let suggestions = DiscoveryIntelligence.suggestions(enquiry, businesses: businesses)
                if suggestions.count == 1 { selected = suggestions.keys.first! }
            }
        }
    }
}

struct DiscoveryFitReviewView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let attention: DiscoveryAttention
    let strategyRevision: UUID?
    @State private var decision: DiscoveryFit
    @State private var reason: String
    @State private var error: String?

    init(attention: DiscoveryAttention, review: DiscoveryFitReview?, strategyRevision: UUID?) {
        self.attention = attention; self.strategyRevision = strategyRevision
        _decision = State(initialValue: attention.fit); _reason = State(initialValue: review?.reason ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Offer fit · " + attention.business.candidate.name).font(.title2.bold())
            Text(store.websiteResearch.kairosContext?.targetingBrief ?? "KAIROS targeting context is unavailable. Record the offer and audience basis in your reason.")
                .font(.caption).textSelection(.enabled)
            Text("Business source: " + attention.business.candidate.sourceURL).font(.caption).textSelection(.enabled)
            Picker("Fit decision", selection: $decision) { ForEach(DiscoveryFit.allCases) { Text($0.label).tag($0) } }
            TextField("Reason and supporting offer/audience evidence", text: $reason, axis: .vertical).lineLimit(3...6)
            Text("This is your explained assessment. Incoming interest and contactability retain their own evidence.").font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.caption).foregroundStyle(CRMTheme.rust) }
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                Spacer()
                Button("Save fit review") {
                    if store.reviewDiscoveryFit(businessKey: attention.id, decision: decision, reason: reason, strategyRevision: strategyRevision) { dismiss() }
                    else { error = store.notice }
                }.disabled(decision != .unassessed && reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(22).frame(minWidth: 620)
    }
}
