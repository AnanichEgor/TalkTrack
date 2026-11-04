import Foundation
import Observation
import TalkTrackDomain

public struct MeetingTranscriptSnapshot: Equatable, Sendable {
    public let meeting: Meeting
    public let recordings: [Recording]
    public let revisions: [TranscriptRevision]
    public let speakers: [DaySpeaker]
    public let assignments: [SpeakerAssignment]
    public var anchors: [FragmentAnchor] = []
    public let items: [TranscriptDisplayItem]
}

/// A selection from a committed transcript, including the scope shown before
/// Save. Only SessionStore can construct one; live candidate IDs are not names.
public struct SpeakerRenameTarget: Equatable, Sendable {
    public let meetingID: UUID
    public let meetingTitle: String
    public let recordingID: UUID
    public let revisionID: UUID
    public let segmentID: UUID
    public let speakerID: UUID
    public let day: RecordingDay
    public let label: String
    public let name: String?
    public let assignmentID: UUID?
    public let assignmentOrigin: SpeakerAssignmentOrigin?
}

public enum SpeakerRenameError: Error, Equatable, LocalizedError, Sendable {
    case invalidName, microphone, unavailable, changed
    public var errorDescription: String? {
        switch self {
        case .invalidName: "Enter a name of 1–200 characters on one line, without control characters."
        case .microphone: "Microphone speech always uses You and cannot be renamed."
        case .unavailable: "This speaker is no longer in the current transcript. Refresh the transcript and select a current speaker."
        case .changed: "The transcript, speaker name or meeting scope changed. Close the dialog, refresh the transcript and select the speaker again."
        }
    }
    public static func validatedName(_ value: String) throws -> String {
        // Check the original input too: trimming must not hide a pasted newline.
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 200,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) }) else {
            throw SpeakerRenameError.invalidName
        }
        return name
    }
}

/// The naming heads of a meeting at one generation; restoring them undoes
/// the Save that followed. Only SessionStore reads them.
public struct NamingHeads: Equatable, Sendable {
    struct Entry: Equatable, Sendable { let kind: String; let scope: String; let id: String }
    public let meetingID: UUID
    public let generation: UInt64
    let entries: [Entry]
}

public enum NamingUndoError: Error, Equatable, LocalizedError, Sendable {
    case changed, profileChanged
    public var errorDescription: String? {
        switch self {
        case .changed: "Names in this meeting changed after that Save, so it can no longer be undone. Rename the reply or voice, or use Remove Reply Name, to correct it."
        case .profileChanged: "The saved voice changed after that Save, so it can no longer be undone. Rename the reply or voice, or use Remove Reply Name, to correct it."
        }
    }
}

/// What one successful Save changed, kept in memory so Undo can take back
/// exactly that: the naming heads before it, the generation it produced, and
/// the saved voice it created or extended. Steps run profile first; each is
/// recorded as done, so a retry skips it.
public struct NamingUndo: Equatable, Sendable {
    public let heads: NamingHeads
    public let generation: UInt64
    /// The voice after the Save, and before it (nil when the Save created it).
    public let created: VoiceProfile?
    public let previous: VoiceProfile?
    public internal(set) var profileUndone = false
}

/// Small native UI projection. SQLite and formatting run on SessionStore's
/// executor. A failed save retains both the current transcript and the draft.
@MainActor @Observable public final class MeetingTranscriptPresentation {
    public private(set) var snapshot: MeetingTranscriptSnapshot?
    public private(set) var renameTarget: SpeakerRenameTarget?
    /// What the sheet names: one reply (its fragments) or its whole voice.
    public enum NamingScope: Equatable, Sendable { case reply, voice }
    public var scope = NamingScope.voice
    /// The selected reply's segments.
    public private(set) var replySegmentIDs: [UUID] = []
    /// Set while the sheet names these fragments instead of their voice.
    public var fragmentSegmentIDs: [UUID]? { renameTarget != nil && scope == .reply ? replySegmentIDs : nil }
    /// Recordings whose voices Apply Names can rebuild without transcribing.
    public private(set) var applicableRecordings: [UUID] = []
    public var draftName = ""
    /// The selected speech's name when the sheet opened (the reply's name, else
    /// its voice's). The field starts empty, so the full saved-voice list shows.
    public private(set) var currentName: String?
    /// Remembering is the default (user decision, 2026-10-13): a chosen or
    /// same-named saved profile receives the speech; any other name creates one.
    public var rememberVoice = true
    /// A suggestion the user picked; otherwise the typed name selects a profile.
    public var selectedProfileID: UUID?
    public var replaceIncompatibleVoice = false
    /// A voice of the day picked for an Unidentified reply instead of a name.
    public private(set) var chosenVoiceID: UUID?
    public private(set) var savedVoices: [SavedVoice] = []
    public private(set) var profiles: [VoiceProfile] = []
    public private(set) var profileLoadError: String?
    public private(set) var noticeMessage: String?
    /// Offered after a Save until another naming change (see NamingUndo).
    public private(set) var undo: NamingUndo?
    public var canUndo: Bool { undo != nil && !isBusy && renameTarget == nil }
    public private(set) var isRemembering = false
    public private(set) var isBusy = false
    public private(set) var errorMessage: String?
    public private(set) var renameError: String?
    private let store: SessionStore
    private let enrollment: VoiceProfileEnrollment?
    @ObservationIgnored private var enrollmentTask: Task<VoiceProfile, any Error>?
    public let meetingID: UUID

    public init(store: SessionStore, meetingID: UUID, enrollment: VoiceProfileEnrollment? = nil) {
        self.store = store; self.meetingID = meetingID; self.enrollment = enrollment
    }
    /// The saved voice named like the current name, listed first and marked.
    public var currentProfileID: UUID? {
        guard let currentName else { return nil }
        return profiles.first { $0.name.compare(currentName, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }?.id
    }
    /// Saved profiles matching the typed name, best matches first: names
    /// starting with it, then containing it. While it is empty, or holds the
    /// name of the voice just picked from the list, every profile: the current
    /// name's first, the rest alphabetically.
    public var suggestions: [VoiceProfile] {
        let typed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        let picked = selectedProfileID.flatMap { id in profiles.first { $0.id == id } }?.name == draftName
        guard !typed.isEmpty, !picked else {
            let sorted = profiles.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            guard let current = currentProfileID, let index = sorted.firstIndex(where: { $0.id == current }) else { return sorted }
            return [sorted[index]] + sorted.enumerated().filter { $0.offset != index }.map(\.element)
        }
        let prefix = profiles.filter { $0.name.range(of: typed, options: [.caseInsensitive, .diacriticInsensitive, .anchored]) != nil }
        let contains = profiles.filter { $0.name.range(of: typed, options: [.caseInsensitive, .diacriticInsensitive]) != nil && !prefix.contains($0) }
        return prefix + contains
    }
    /// The profile that receives the speech: the picked suggestion, else the
    /// saved profile whose name equals the typed one; nil creates a new profile.
    public var effectiveProfileID: UUID? {
        if let selectedProfileID { return selectedProfileID }
        let typed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        return profiles.first { $0.name.compare(typed, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }?.id
    }
    public func chooseProfile(_ profile: VoiceProfile) {
        draftName = profile.name; selectedProfileID = profile.id; replaceIncompatibleVoice = false
    }
    public func clearProfileChoice() { selectedProfileID = nil; replaceIncompatibleVoice = false }
    public var selectedProfileNeedsNewSpeech: Bool { savedVoices.first { $0.id == effectiveProfileID }?.needsNewSpeech == true }
    public var canSave: Bool { !isBusy && (chosenVoiceID != nil || (try? SpeakerRenameError.validatedName(draftName)) != nil &&
        (!rememberVoice || !selectedProfileNeedsNewSpeech || replaceIncompatibleVoice)) }

    /// The sheet is open for an Unidentified reply: it names that reply only,
    /// and its speech is too short or mixed to remember as a voice.
    public var namingUnidentified: Bool {
        guard let target = renameTarget else { return false }
        return snapshot?.speakers.first { $0.id == target.speakerID }?.unidentified == true
    }
    public struct DayVoice: Equatable, Identifiable, Sendable {
        public let id: UUID
        public let label: String
        /// The voice's name, when it has one; a named voice is chosen by name.
        public let name: String?
    }
    /// The voices heard on the target's day, for saying who said an Unidentified reply.
    public var dayVoices: [DayVoice] {
        guard let target = renameTarget, let snapshot else { return [] }
        let used = Set(snapshot.revisions.flatMap(\.segments).compactMap { segment -> UUID? in
            if case .system(let id) = segment.speaker { id } else { nil }
        })
        return snapshot.speakers.filter { !$0.unidentified && used.contains($0.id) && $0.recordingDayIDs.contains(target.day.id) }
            .sorted { $0.number < $1.number }
            .map { speaker in
                let name = snapshot.assignments.first { $0.daySpeakerID == speaker.id }?.name
                return DayVoice(id: speaker.id, label: name ?? "Voice\(speaker.number)", name: name)
            }
    }
    public func chooseVoice(_ voice: DayVoice) {
        draftName = voice.label; selectedProfileID = nil; replaceIncompatibleVoice = false
        chosenVoiceID = voice.name == nil ? voice.id : nil
    }
    /// Typing another name than the chosen voice's label names the reply instead.
    public func draftNameChanged() {
        if let id = chosenVoiceID, dayVoices.first(where: { $0.id == id })?.label != draftName { chosenVoiceID = nil }
    }

    public func refresh() async {
        guard !isBusy else { return }
        isBusy = true; defer { isBusy = false }
        do {
            snapshot = try await store.meetingTranscript(meetingID: meetingID); errorMessage = nil
            if let undo, snapshot?.meeting.generation != undo.generation { self.undo = nil }
            applicableRecordings = try await store.namesApplicableRecordings(meetingID: meetingID)
        }
        catch { errorMessage = error.localizedDescription }
    }
    public func beginRename(recordingID: UUID, segmentID: UUID) async {
        await begin(recordingID: recordingID, segmentIDs: [segmentID], scope: .voice)
    }
    /// `Name This Reply…` for a displayed block's segments.
    public func beginNameFragment(recordingID: UUID, segmentIDs: [UUID]) async {
        await begin(recordingID: recordingID, segmentIDs: segmentIDs, scope: .reply)
    }
    /// Selecting a speaker's name names this reply only (user request,
    /// 2026-10-14): diarization numbers are not reliable enough to rename every
    /// reply of a voice; that stays an explicit choice in the sheet.
    public func beginNaming(recordingID: UUID, segmentIDs: [UUID]) async {
        await begin(recordingID: recordingID, segmentIDs: segmentIDs, scope: nil)
    }
    private func fragmentName(_ ids: [UUID]) -> String? {
        let segments = snapshot?.revisions.flatMap(\.segments).filter { ids.contains($0.id) } ?? []
        return snapshot?.anchors.filter { anchor in anchor.voiceID == nil && segments.contains(where: anchor.covers) }
            .max { $0.createdAt < $1.createdAt }?.name
    }
    private func begin(recordingID: UUID, segmentIDs: [UUID], scope requested: NamingScope?) async {
        guard !isBusy, renameTarget == nil, let first = segmentIDs.first else { return }
        isBusy = true; defer { isBusy = false }
        do {
            let target = try await store.speakerRenameTarget(meetingID: meetingID, recordingID: recordingID, segmentID: first)
            let named = fragmentName(segmentIDs)
            replySegmentIDs = segmentIDs
            let unidentified = snapshot?.speakers.first { $0.id == target.speakerID }?.unidentified == true
            scope = unidentified ? .reply : requested ?? .reply
            currentName = (scope == .reply ? named : nil) ?? target.name
            draftName = ""; rememberVoice = !unidentified; selectedProfileID = nil
            chosenVoiceID = nil
            replaceIncompatibleVoice = false; savedVoices = []
            profiles = []; profileLoadError = nil; noticeMessage = nil
            if let enrollment {
                do {
                    guard let revision = try await store.transcript(meetingID: meetingID, recordingID: recordingID) else { throw SpeakerRenameError.unavailable }
                    savedVoices = try await enrollment.availableSavedVoices(models: revision.modelRevisions); profiles = savedVoices.map(\.profile)
                }
                catch { profileLoadError = error.localizedDescription }
            } else { profileLoadError = VoiceEnrollmentError.unavailable.localizedDescription }
            renameError = nil; errorMessage = nil; renameTarget = target
        } catch { errorMessage = error.localizedDescription }
    }
    public var hasSpeakerNames: Bool { !(snapshot?.assignments.isEmpty ?? true) || !(snapshot?.anchors.isEmpty ?? true) }
    /// Names or named fragments exist and a recording can be rebuilt from them.
    public var canApplyNames: Bool { !isBusy && renameTarget == nil && !applicableRecordings.isEmpty && hasSpeakerNames }
    /// Rebuilds the meeting's voices from the current names without transcribing again.
    public func applyNames() async {
        guard canApplyNames else { return }
        isBusy = true; defer { isBusy = false }
        undo = nil
        do {
            let published = try await store.applyNames(meetingID: meetingID)
            snapshot = try await store.meetingTranscript(meetingID: meetingID)
            applicableRecordings = try await store.namesApplicableRecordings(meetingID: meetingID)
            errorMessage = nil
            let recognized = published.reduce(0) { $0 + ($1.recognizedReplies ?? 0) }
            let active = published.contains { $0.replyRecognition?.isActive == true }
            noticeMessage = published.isEmpty ? "No recording could be rebuilt. Reprocess the meeting to apply names."
                : !active ? "Names applied. Recognition needs more named replies: name at least two replies of a person, at different moments, and a reply of someone else."
                : "Names applied: \(recognized) more repl\(recognized == 1 ? "y was" : "ies were") recognized from your named replies; the rest stay VoiceN. The words are unchanged."
        } catch { errorMessage = error.localizedDescription }
    }
    /// Removes the fragment names shown on a block; its voice name returns,
    /// and saved voices stop using the reply's speech (after the name removal;
    /// a failure there keeps the withdrawal for Retry).
    public func removeFragmentName(recordingID: UUID, segmentIDs: [UUID]) async {
        guard !isBusy, renameTarget == nil else { return }
        isBusy = true; defer { isBusy = false }
        undo = nil
        do {
            let removed = try await store.removeFragmentNames(meetingID: meetingID, recordingID: recordingID, segmentIDs: segmentIDs)
            snapshot = removed.snapshot
            errorMessage = nil; noticeMessage = nil
            pendingWithdrawals = removed.withdrawals
            await recordWithdrawals()
        } catch { errorMessage = error.localizedDescription }
    }
    /// Speech of removed reply names not yet recorded for saved voices.
    public private(set) var pendingWithdrawals: [VoiceWithdrawal] = []
    private func recordWithdrawals() async {
        guard !pendingWithdrawals.isEmpty, let enrollment else { pendingWithdrawals = []; return }
        do { try await enrollment.withdraw(pendingWithdrawals); pendingWithdrawals = [] }
        catch {
            errorMessage = "The reply name is removed, but saved voices still use its speech: \(error.localizedDescription) Choose Retry."
        }
    }
    /// The error row's Retry: a pending withdrawal first, otherwise a refresh.
    public func retry() async {
        if pendingWithdrawals.isEmpty { await refresh(); return }
        guard !isBusy else { return }
        isBusy = true; defer { isBusy = false }
        errorMessage = nil
        await recordWithdrawals()
    }
    public func clearSpeakerNames() async {
        guard !isBusy, renameTarget == nil else { return }
        isBusy = true; defer { isBusy = false }
        undo = nil
        do { snapshot = try await store.clearSpeakerNames(meetingID: meetingID); errorMessage = nil; noticeMessage = nil }
        catch { errorMessage = error.localizedDescription }
    }
    /// Takes back the last Save: the saved voice first (where samples are at
    /// risk), then the names. Refused once names or that voice changed since.
    public func undoLastNaming() async {
        guard canUndo, var token = undo else { return }
        isBusy = true; defer { isBusy = false }
        let voice = token.created?.name
        do {
            guard try await store.namingHeads(meetingID: meetingID).generation == token.generation else { throw NamingUndoError.changed }
            if let created = token.created, !token.profileUndone {
                guard let enrollment else { throw VoiceEnrollmentError.unavailable }
                do { try await enrollment.undoEnrollment(created: created, previous: token.previous) }
                catch VoiceProfileSettingsError.changed { throw NamingUndoError.profileChanged }
                token.profileUndone = true; undo = token
            }
            snapshot = try await store.undoNaming(token.heads, generation: token.generation)
            undo = nil; errorMessage = nil
            noticeMessage = "Undone: the previous names are back."
                + (voice.map { token.previous == nil ? " The saved voice \($0) was removed." : " \($0) has only its earlier samples again." } ?? "")
        } catch let error as NamingUndoError {
            undo = nil; noticeMessage = nil
            errorMessage = error.localizedDescription
                + (token.profileUndone ? " \(voice ?? "The saved voice") already has only its earlier samples again." : "")
        } catch {
            noticeMessage = nil
            errorMessage = token.profileUndone
                ? "\(voice ?? "The saved voice") has only its earlier samples again, but the names were not restored: \(error.localizedDescription) Choose Undo to try again."
                : "Nothing was undone: \(error.localizedDescription) Choose Undo to try again."
        }
    }
    public func cancelRename() {
        guard !isBusy else { return }
        renameTarget = nil; replySegmentIDs = []; scope = .voice; draftName = ""; currentName = nil; renameError = nil; rememberVoice = true; selectedProfileID = nil
        replaceIncompatibleVoice = false; chosenVoiceID = nil
    }
    public func cancelRemembering() { enrollmentTask?.cancel() }
    public func saveRename() async {
        guard !isBusy, let target = renameTarget else { return }
        isBusy = true; defer { isBusy = false }
        undo = nil
        do {
            let place = fragmentSegmentIDs == nil ? "this meeting day" : "this reply"
            let heads = try await store.namingHeads(meetingID: meetingID)
            var remembered: (created: VoiceProfile, previous: VoiceProfile?)?
            if let voice = chosenVoiceID, let ids = fragmentSegmentIDs {
                snapshot = try await store.assignFragment(meetingID: meetingID, recordingID: target.recordingID, segmentIDs: ids, voiceID: voice)
                noticeMessage = nil
            } else if rememberVoice {
                let saved: ConfirmedSpeakerRename
                if let ids = fragmentSegmentIDs {
                    saved = try await store.nameFragmentWithConfirmation(meetingID: meetingID, recordingID: target.recordingID, segmentIDs: ids, name: draftName)
                } else { saved = try await store.renameSpeakerWithConfirmation(target, name: draftName) }
                snapshot = saved.snapshot
                // Errors below concern remembering only. The name is durable.
                do {
                    if let profileLoadError { throw VoiceEnrollmentError.profileLibrary(profileLoadError) }
                    guard let enrollment else { throw VoiceEnrollmentError.unavailable }
                    let choice: VoiceProfileChoice
                    if let profileID = effectiveProfileID {
                        guard let profile = profiles.first(where: { $0.id == profileID }) else { throw VoiceEnrollmentError.changed }
                        if selectedProfileNeedsNewSpeech {
                            guard replaceIncompatibleVoice else { throw VoiceEnrollmentError.incompatibleModels }
                            choice = .replaceIncompatible(profileID: profile.id, revisionID: profile.revisionID)
                        } else { choice = .existing(profileID: profile.id, revisionID: profile.revisionID) }
                    } else { choice = .newProfile }
                    isRemembering = true
                    let task = Task { try await enrollment.enroll(saved.confirmation, choice: choice) }
                    enrollmentTask = task
                    defer { enrollmentTask = nil; isRemembering = false }
                    let profile = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
                    remembered = (profile, profiles.first { $0.id == profile.id })
                    noticeMessage = "Name saved for \(place). Voice remembered locally as \(profile.name)."
                } catch is CancellationError {
                    noticeMessage = "Name saved for \(place). Voice remembering was cancelled."
                } catch {
                    noticeMessage = "Name saved for \(place). Voice was not remembered. \(error.localizedDescription)"
                }
            } else if let ids = fragmentSegmentIDs {
                snapshot = try await store.nameFragment(meetingID: meetingID, recordingID: target.recordingID, segmentIDs: ids, name: draftName)
                noticeMessage = nil
            } else {
                snapshot = try await store.renameSpeaker(target, name: draftName)
                noticeMessage = nil
            }
            // Undo only when nothing else changed the names between reading them and the Save.
            if let generation = snapshot?.meeting.generation, generation == heads.generation + 1 {
                undo = NamingUndo(heads: heads, generation: generation, created: remembered?.created, previous: remembered?.previous)
            }
            renameTarget = nil; replySegmentIDs = []; scope = .voice; draftName = ""; currentName = nil; renameError = nil; errorMessage = nil
            rememberVoice = true; selectedProfileID = nil; chosenVoiceID = nil
            replaceIncompatibleVoice = false
        } catch {
            renameError = error.localizedDescription
            // Retain a visible Retry action after closing a stale/error dialog.
            errorMessage = error.localizedDescription
        }
    }
}
