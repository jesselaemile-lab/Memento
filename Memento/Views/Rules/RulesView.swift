import SwiftUI

struct RulesView: View {
    @Environment(AppViewModel.self) private var appVM

    var body: some View {
        @Bindable var vm = appVM
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                rulesHeader
                VStack(alignment: .leading, spacing: 32) {
                    namingSection(rules: $vm.rules)
                    MDivider()
                    eventSection(rules: $vm.rules)
                    MDivider()
                    safetySection
                    MDivider()
                    mediaSection(rules: $vm.rules)
                }
                .padding(28)
            }
        }
        .background(Color.mGround)
    }

    // MARK: - Header

    private var rulesHeader: some View {
        MScreenHeader("Rules", subtitle: "How Memento names and groups your library") {
            MPillButton("Reset to defaults", icon: "arrow.counterclockwise", style: .secondary) {
                appVM.rules = .default
            }
        }
    }

    // MARK: - Naming

    private func namingSection(rules: Binding<GroupingRules>) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Naming").font(.mHeadline).foregroundStyle(Color.mText)

            VStack(alignment: .leading, spacing: 8) {
                Text("Folder structure").font(.mLabel).foregroundStyle(Color.mText.opacity(0.55))
                MSegmentedPicker(selection: rules.structureMode,
                                 options: GroupingRules.StructureMode.allCases) { $0.rawValue }
            }

            if rules.wrappedValue.structureMode == .people {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Inside each person's folder").font(.mLabel).foregroundStyle(Color.mText.opacity(0.55))
                    MSegmentedPicker(selection: rules.peopleSubStructure,
                                     options: GroupingRules.PeopleSubStructure.allCases) { $0.rawValue }
                    Text("After scanning you'll name the people found. Example: Jesse/\(peopleExample(rules.wrappedValue.peopleSubStructure))")
                        .font(.mCaption)
                        .foregroundStyle(Color.mText.opacity(0.5))
                }

                ruleSlider(
                    label: "Face matching",
                    value: rules.faceMatchDistance,
                    range: 0.3...1.0, step: 0.05,
                    display: String(format: "%.2f", rules.wrappedValue.faceMatchDistance)
                )
                Text("Lower is stricter: fewer mixed-up people, but one person may be split into several clusters.")
                    .font(.mCaption)
                    .foregroundStyle(Color.mText.opacity(0.5))
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Naming template").font(.mLabel).foregroundStyle(Color.mText.opacity(0.55))
                TextField("{event}", text: rules.namingTemplate)
                    .textFieldStyle(.roundedBorder)
                Text("Preview: \(applyTemplate(rules.wrappedValue.namingTemplate))")
                    .font(.mCaption)
                    .foregroundStyle(Color.mText.opacity(0.5))
                    .padding(.top, 2)
                tokenBar
            }
        }
    }

    private func peopleExample(_ mode: GroupingRules.PeopleSubStructure) -> String {
        switch mode {
        case .yearMonth: "2026/12-December"
        case .yearEvent: "2026/12-December/Christmas"
        case .place:     "San Francisco"
        }
    }

    private var tokenBar: some View {
        let tokens = ["{yyyy}", "{mm}", "{dd}", "{event}", "{place}", "{person}", "{camera}"]
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(tokens, id: \.self) { token in
                    Text(token)
                        .font(.mCaption)
                        .foregroundStyle(Color.mTerracottaDeep)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.mTerracottaTint)
                        .clipShape(Capsule())
                }
            }
        }
    }

    private func applyTemplate(_ t: String) -> String {
        t.replacingOccurrences(of: "{yyyy}",   with: "2024")
         .replacingOccurrences(of: "{mm}",     with: "08")
         .replacingOccurrences(of: "{dd}",     with: "15")
         .replacingOccurrences(of: "{event}",  with: "Beach Trip")
         .replacingOccurrences(of: "{place}",  with: "Malibu")
         .replacingOccurrences(of: "{person}", with: "Jesse")
         .replacingOccurrences(of: "{camera}", with: "iPhone 15")
    }

    // MARK: - Event detection

    private func eventSection(rules: Binding<GroupingRules>) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Event detection").font(.mHeadline).foregroundStyle(Color.mText)

            VStack(alignment: .leading, spacing: 8) {
                Text("Organize by").font(.mLabel).foregroundStyle(Color.mText.opacity(0.55))
                MSegmentedPicker(selection: rules.dateBasis,
                                 options: GroupingRules.DateBasis.allCases) { $0.rawValue }
                Text(rules.wrappedValue.dateBasis == .dateCreated
                     ? "Uses each file's Date Created, as shown in Finder."
                     : "Uses the date stored in the photo by the camera; files without one use their Date Created.")
                    .font(.mCaption)
                    .foregroundStyle(Color.mText.opacity(0.5))
            }

            ruleSlider(
                label: "Time gap",
                value: rules.timeGapHours,
                range: 1...72, step: 1,
                display: "\(Int(rules.wrappedValue.timeGapHours)) h"
            )

            ruleSlider(
                label: "Location jump",
                value: rules.locationGapKilometers,
                range: 1...200, step: 5,
                display: "\(Int(rules.wrappedValue.locationGapKilometers)) km"
            )

            ruleSlider(
                label: "Minimum items per event",
                value: Binding(
                    get: { Double(rules.wrappedValue.minimumItemsPerGroup) },
                    set: { rules.wrappedValue.minimumItemsPerGroup = Int($0) }
                ),
                range: 1...50, step: 1,
                display: "\(rules.wrappedValue.minimumItemsPerGroup) items"
            )

            ruleToggle("Recognize holidays in naming", isOn: rules.recognizeHolidays)
            ruleToggle("Keep old album folder names as subfolders", isOn: rules.reuseSourceFolderNames)
        }
    }

    private func ruleSlider(label: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, display: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label).font(.mLabel).foregroundStyle(Color.mText.opacity(0.55))
                Spacer()
                Text(display).font(.mBodySemi).foregroundStyle(Color.mText)
            }
            Slider(value: value, in: range, step: step)
                .tint(Color.mTerracotta)
        }
    }

    private func ruleToggle(_ label: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(label).font(.mBody).foregroundStyle(Color.mText)
        }
        .toggleStyle(.switch)
        .tint(Color.mTerracotta)
    }

    // MARK: - Safety (locked)

    private var safetySection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Text("Safety").font(.mHeadline).foregroundStyle(Color.mText)
                MTag("Locked", color: .mTerracottaTint, textColor: .mTerracottaDeep)
            }

            VStack(spacing: 10) {
                lockedRule(icon: "trash.slash.fill",
                    title: "Never delete user media",
                    detail: "Duplicates move to quarantine. Source folders go to Trash only on explicit confirmation.")
                lockedRule(icon: "checkmark.shield.fill",
                    title: "Verify before releasing source",
                    detail: "Copy → SHA-256 both sides → only then remove source. Mismatch aborts and logs.")
                lockedRule(icon: "doc.text.fill",
                    title: "Journal every file operation",
                    detail: "JSONL append-only log, fsync'd after each entry. Any run or checkpoint can be reverted.")
                lockedRule(icon: "clock.fill",
                    title: "Checkpoint every 30 seconds",
                    detail: "Crash or disconnected drive loses at most 30 seconds of work.")
                lockedRule(icon: "photo.stack.fill",
                    title: "Refuse managed libraries",
                    detail: ".photoslibrary and .lrlibrary bundles are skipped and never written to.")
                lockedRule(icon: "doc.badge.plus",
                    title: "Never overwrite on filename collision",
                    detail: "Conflicting names get a (2), (3)… suffix automatically.")
            }
        }
    }

    private func lockedRule(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.mSage)
                .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: icon).foregroundStyle(Color.mText.opacity(0.55)).frame(width: 16)
                    Text(title).font(.mBodySemi).foregroundStyle(Color.mText)
                }
                Text(detail)
                    .font(.mCaption)
                    .foregroundStyle(Color.mText.opacity(0.55))
                    .lineLimit(4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.mSurface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.mBorder, lineWidth: 1))
    }

    // MARK: - Videos & screenshots

    private func mediaSection(rules: Binding<GroupingRules>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Scan options").font(.mHeadline).foregroundStyle(Color.mText)
            VStack(spacing: 6) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("What to organize").font(.mBodySemi).foregroundStyle(Color.mText)
                        Text("Photos only skips videos — Live Photo clips stay with their photo.")
                            .font(.mCaption).foregroundStyle(Color.mText.opacity(0.5))
                    }
                    Spacer()
                    MSegmentedPicker(selection: rules.mediaFilter,
                                     options: GroupingRules.MediaFilter.allCases) { $0.rawValue }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color.mSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                scanOptionToggle("Include screenshots in events",
                                 description: "Organizes screenshots into the library instead of skipping them.",
                                 isOn: rules.includeScreenshots)
                scanOptionToggle("Include sidecar files (.xmp, .aae)",
                                 description: "Keeps XMP and AAE edit files alongside their photos.",
                                 isOn: rules.includeSidecars)
                scanOptionToggle("Scan nested subfolders",
                                 description: "Includes all folders inside your source, not just the top level.",
                                 isOn: rules.scanNestedSubfolders)
                scanOptionToggle("Follow symlinks",
                                 description: "Traverses symlinks as real folders. Avoid unless you know you need it.",
                                 isOn: rules.followSymlinks)
                scanOptionToggle("Read GPS location from photos",
                                 description: "Reads GPS coordinates from EXIF to name events by place.",
                                 isOn: rules.enableLocationReading)
            }
        }
    }

    private func scanOptionToggle(_ label: String, description: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.mBodySemi)
                    .foregroundStyle(Color.mText)
                Text(description)
                    .font(.mCaption)
                    .foregroundStyle(Color.mText.opacity(0.5))
            }
            Spacer()
            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .tint(Color.mTerracotta)
                .labelsHidden()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.mSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
