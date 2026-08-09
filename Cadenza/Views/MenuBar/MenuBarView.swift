import SwiftUI
import AVFoundation
import CoreAudio

struct MenuBarView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.locale) private var locale
    @AppStorage("selectedMicrophoneID") private var selectedMicrophoneID = ""
    @AppStorage("selectedOutputDeviceID") private var selectedOutputDeviceID = ""
    @AppStorage("autoRecordMeetings") private var autoRecordMeetings = false
    @AppStorage("enableMeetingDetection") private var enableMeetingDetection = false
    @State private var weekEvents: [MeetingEvent] = []

    var body: some View {
        // Status
        if let meetingName = appState.currentMeetingName {
            Text("\(appState.statusText) — \(meetingName)")
        } else {
            Text(appState.statusText)
        }

        if appState.startupPolicy.allowsHardwareCapture {
            if let recordingError = appState.recordingError {
                Divider()
                Label("Recording Error", systemImage: "exclamationmark.triangle.fill")
                Text(recordingError)
                if appState.recordingErrorOffersSystemAudioSettings {
                    Button("Open System Audio Settings") {
                        Permissions.openSystemAudioRecordingSettings()
                        appState.dismissRecordingError()
                    }
                }
                Button("Dismiss") {
                    appState.dismissRecordingError()
                }
            }

            Divider()

            // Recording controls
            if appState.isRecording {
                Button("Stop Recording") {
                    appState.stopRecording()
                }
                .keyboardShortcut(".", modifiers: .command)
            } else if appState.isFinalizingRecording {
                Button("Saving recording…") {}
                    .disabled(true)
            } else if appState.isStartingRecording {
                // Multi-second async window before recordingState flips to .recording.
                // Disabled so the user can't fire a second (silently swallowed) start.
                Button("Starting…") {}
                    .disabled(true)
            } else {
                Button("Start Recording") {
                    Task {
                        do { try await appState.startRecording() }
                        catch {
                            appState.presentStartRecordingError(error)
                            openWindow(id: "main")
                            NSApp.activate(ignoringOtherApps: true)
                        }
                    }
                }
                .keyboardShortcut("r", modifiers: .command)
            }

            Divider()

            // Audio submenu
            Menu("Audio") {
                Section("Input") {
                    Picker("Microphone", selection: $selectedMicrophoneID) {
                        Text("Default").tag("")
                        ForEach(inputDevices, id: \.uniqueID) { device in
                            Text(device.localizedName).tag(device.uniqueID)
                        }
                    }
                }

                Section("Output") {
                    Picker("Output", selection: $selectedOutputDeviceID) {
                        Text("Default").tag("")
                        ForEach(outputDevices, id: \.id) { device in
                            Text(device.name).tag(device.id)
                        }
                    }
                }
            }

            // Meeting submenu
            Menu("Meeting") {
                Toggle("Detect meeting apps", isOn: $enableMeetingDetection)
                    .onChange(of: enableMeetingDetection) { _, newValue in
                        appState.setMeetingDetectionEnabled(newValue)
                    }
                if autoRecordMeetings {
                    Toggle("Auto start recording", isOn: $autoRecordMeetings)
                } else {
                    Button("Auto-record meetings") {
                        appState.openSettings(category: .recording)
                        openWindow(id: "main")
                        NSApp.activate(ignoringOtherApps: true)
                    }
                }
                if !appState.hasPreparedSystemAudioCapture {
                    Button("Set Up System Audio Recording…") {
                        appState.openSettings(category: .recording)
                        openWindow(id: "main")
                        NSApp.activate(ignoringOtherApps: true)
                    }
                }
            }

            Divider()
        }

        // Upcoming events inline (not submenu)
        Group {
            if weekEvents.isEmpty {
                Text("No events this week")
            } else {
                ForEach(groupedWeekEvents(weekEvents), id: \.key) { dayLabel, dayEvents in
                    Section(dayLabel) {
                        ForEach(dayEvents) { event in
                            Button {
                                openCalendar(for: event)
                            } label: {
                                Label {
                                    Text(eventLabel(event))
                                } icon: {
                                    Image(systemName: "circle.fill")
                                        .foregroundStyle(event.displayColor)
                                }
                            }
                        }
                    }
                }
            }
        }
        .onAppear { loadWeekEvents() }

        Divider()

        Button("Open Cadenza") {
            revealMainWindow()
        }

        Button("Settings...") {
            revealMainWindow()
            appState.openSettings(category: .general)
        }
        .keyboardShortcut(",", modifiers: .command)

        Divider()

        Button("Quit Cadenza") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }

    // MARK: - Audio Devices

    private var inputDevices: [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone],
            mediaType: .audio,
            position: .unspecified
        ).devices
    }

    private var outputDevices: [AudioOutputDevice] {
        AudioOutputDevice.allOutputDevices()
    }

    // MARK: - Calendar Helpers

    private func revealMainWindow() {
        let runInBackground = UserDefaults.standard.bool(forKey: "runInBackground")
        if runInBackground {
            NSApp.setActivationPolicy(.regular)
        }
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }

    private func openCalendar(for _: MeetingEvent) {
        revealMainWindow()
        appState.navigate(to: .calendar)
    }

    private func loadWeekEvents() {
        let now = Date()
        let calendar = Calendar.current
        // End of current week (Sunday night or locale-dependent)
        let weekInterval = calendar.dateInterval(of: .weekOfYear, for: now)!
        let weekEnd = weekInterval.end
        appState.fetchEvents(from: now, to: weekEnd) { dtos in
            self.weekEvents = dtos.map { dto in
                MeetingEvent(
                    id: dto.id,
                    title: dto.title,
                    startDate: dto.startDate,
                    endDate: dto.endDate,
                    meetingURL: dto.meetingURL.flatMap { URL(string: $0) },
                    meetingApp: dto.meetingApp.flatMap { MeetingApp(rawValue: $0) },
                    calendarName: dto.calendarName,
                    notes: dto.notes,
                    source: CalendarSource(rawValue: dto.source) ?? .apple,
                    calendarID: dto.calendarID,
                    defaultColorHex: dto.defaultColorHex,
                    organizer: dto.organizer,
                    attendees: dto.attendees.map { att in
                        EventAttendee(
                            name: att.name,
                            email: att.email,
                            isOrganizer: att.isOrganizer,
                            status: AttendeeStatus(rawValue: att.status) ?? .unknown,
                            isCurrentUser: att.isCurrentUser
                        )
                    },
                    isRecurring: dto.isRecurring,
                    location: dto.location,
                    providerEventID: dto.providerEventID,
                    occurrenceAnchor: dto.occurrenceAnchor,
                    availability: EventAvailability(rawValue: dto.availability) ?? .busy
                )
            }
        }
    }

    private func groupedWeekEvents(_ events: [MeetingEvent]) -> [(key: String, value: [MeetingEvent])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: events) { event -> String in
            if calendar.isDateInToday(event.startDate) {
                return LocalizedBundle.string("Today", locale: locale)
            } else if calendar.isDateInTomorrow(event.startDate) {
                return LocalizedBundle.string("Tomorrow", locale: locale)
            } else {
                return LocalizedDateFormatting.string(
                    from: event.startDate,
                    style: .dateTime.weekday(.abbreviated).month(.abbreviated).day(),
                    locale: locale,
                    calendar: calendar
                )
            }
        }
        return grouped.sorted { lhs, rhs in
            let lDate = lhs.value.first?.startDate ?? .distantFuture
            let rDate = rhs.value.first?.startDate ?? .distantFuture
            return lDate < rDate
        }
    }

    private func eventLabel(_ event: MeetingEvent) -> String {
        if event.isAllDay {
            return LocalizedBundle.string("All Day", locale: locale) + " — \(event.title)"
        }
        let time = LocalizedDateFormatting.string(
            from: event.startDate,
            style: .dateTime.hour(.defaultDigits(amPM: .abbreviated)).minute(),
            locale: locale
        )
        if let app = event.meetingApp {
            return "\(time)  \(event.title) (\(app.displayName))"
        }
        return "\(time)  \(event.title)"
    }
}

// MARK: - Audio Output Device Helper

struct AudioOutputDevice: Identifiable {
    let id: String
    let name: String

    static func allOutputDevices() -> [AudioOutputDevice] {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0, nil,
            &dataSize
        )
        guard status == noErr else { return [] }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0, nil,
            &dataSize,
            &deviceIDs
        )
        guard status == noErr else { return [] }

        return deviceIDs.compactMap { deviceID -> AudioOutputDevice? in
            // Check if device has output streams
            var streamAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            var streamSize: UInt32 = 0
            let streamStatus = AudioObjectGetPropertyDataSize(deviceID, &streamAddress, 0, nil, &streamSize)
            guard streamStatus == noErr, streamSize > 0 else { return nil }

            // Get device name
            var nameAddress = AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertyName,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var nameRef: Unmanaged<CFString>?
            var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            let nameStatus = AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, &nameRef)
            guard nameStatus == noErr, let name = nameRef?.takeRetainedValue() else { return nil }

            return AudioOutputDevice(id: String(deviceID), name: name as String)
        }
    }
}
