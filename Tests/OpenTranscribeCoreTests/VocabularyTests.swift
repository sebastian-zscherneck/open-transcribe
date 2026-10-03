import Foundation
import Testing
@testable import OpenTranscribeCore

// MARK: - CorrectionGuard

@Test func guardRejectsUnlistedWordSwap() {
    let result = CorrectionGuard.apply(
        original: "sehr gerne", proposal: "sehr gern", terms: ["Dashboard", "sellerboard"]
    )
    #expect(result == "sehr gerne")
}

@Test func guardAcceptsMultiWordSpanCollapsingToATerm() {
    let result = CorrectionGuard.apply(
        original: "Amazon das Boat", proposal: "Amazon Dashboard", terms: ["Dashboard"]
    )
    #expect(result == "Amazon Dashboard")
}

@Test func guardAcceptsMultiWordSpanCollapsingToASellerboardTerm() {
    let result = CorrectionGuard.apply(
        original: "aus Sella Boat laufen", proposal: "aus sellerboard laufen", terms: ["sellerboard"]
    )
    #expect(result == "aus sellerboard laufen")
}

@Test func guardIgnoresACompleteRewording() {
    let original = "Wir sollten das Budget nächste Woche nochmal besprechen."
    let proposal = "Lasst uns den kompletten Etat in der kommenden Woche neu aufsetzen und alles überdenken."
    let result = CorrectionGuard.apply(original: original, proposal: proposal, terms: ["Dashboard"])
    #expect(result == original)
}

@Test func guardIgnoresAddedSentences() {
    let original = "Klar, gerne."
    let proposal = "Klar, gerne. Ich schicke dir die Unterlagen morgen zu."
    let result = CorrectionGuard.apply(original: original, proposal: proposal, terms: ["Dashboard"])
    #expect(result == original)
}

@Test func guardIgnoresDeletedSentences() {
    let original = "Klar, gerne. Bis dann."
    let proposal = "Klar, gerne."
    let result = CorrectionGuard.apply(original: original, proposal: proposal, terms: ["Dashboard"])
    #expect(result == original)
}

@Test func guardReturnsOriginalUnchangedWhenTermListIsEmpty() {
    let original = "aus Sella Boat laufen"
    let result = CorrectionGuard.apply(original: original, proposal: "aus sellerboard laufen", terms: [])
    #expect(result == original)
}

@Test func guardPreservesOriginalPunctuationAndCasingWhereNotReplaced() {
    let original = "Moin, wie läuft's mit Sella Boat?"
    let proposal = "Moin, wie läuft's mit sellerboard?"
    let result = CorrectionGuard.apply(original: original, proposal: proposal, terms: ["sellerboard"])
    #expect(result == "Moin, wie läuft's mit sellerboard?")
}

@Test func guardMatchesTermsCaseAndDiacriticInsensitivelyAndWritesTheDictionarySpelling() {
    let result = CorrectionGuard.apply(
        original: "wir nutzen enatenach dafuer", proposal: "wir nutzen Enatena dafuer", terms: ["Enatena"]
    )
    // Matching ignores case, but the accepted term is written the way the dictionary spells it.
    #expect(result == "wir nutzen Enatena dafuer")
}

// A term the recogniser mangled beyond recognition is deliberately left alone. Digits are the
// worst case: nothing about "enatenacht" resembles "n8n" in writing, and inventing a phonetic
// expansion to bridge that gap would reopen the door to confident wrong replacements.
@Test func guardLeavesAnUnrecognisablyMangledTermAlone() {
    let result = CorrectionGuard.apply(
        original: "wir nutzen enatenacht dafuer", proposal: "wir nutzen n8n dafuer", terms: ["n8n"]
    )
    #expect(result == "wir nutzen enatenacht dafuer")
}

@Test func guardHandlesEmptyOriginal() {
    #expect(CorrectionGuard.apply(original: "", proposal: "irgendwas", terms: ["Dashboard"]) == "")
}

// MARK: - PersonalDictionary

@Test func personalDictionaryLoadsFromInjectedUserDefaultsSuite() throws {
    let suiteName = "ot-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(["n8n", "Bitwarden"], forKey: PersonalDictionary.wisperCloneKey)

    let paths = Paths(
        root: makeTempDir(), wikiRaw: makeTempDir()
    )
    let terms = PersonalDictionary.load(paths: paths, suiteName: suiteName)
    #expect(terms == ["n8n", "Bitwarden"])
}

@Test func personalDictionaryMergesExtraVocabularyFromSettingsFile() throws {
    let suiteName = "ot-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(["n8n"], forKey: PersonalDictionary.wisperCloneKey)

    let root = makeTempDir()
    let paths = Paths(root: root, wikiRaw: makeTempDir())
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let json = #"{"extraVocabulary": ["sellerboard", "Dashboard"]}"#
    try Data(json.utf8).write(to: paths.settingsFile)

    let terms = PersonalDictionary.load(paths: paths, suiteName: suiteName)
    #expect(terms == ["n8n", "sellerboard", "Dashboard"])
}

@Test func personalDictionaryDedupesCaseAndDiacriticInsensitively() throws {
    let suiteName = "ot-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(["Mühlenbäcker", "MUHLENBACKER"], forKey: PersonalDictionary.wisperCloneKey)

    let root = makeTempDir()
    let paths = Paths(root: root, wikiRaw: makeTempDir())
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let json = #"{"extraVocabulary": ["muhlenbacker"]}"#
    try Data(json.utf8).write(to: paths.settingsFile)

    let terms = PersonalDictionary.load(paths: paths, suiteName: suiteName)
    #expect(terms == ["Mühlenbäcker"])
}

@Test func personalDictionaryReturnsEmptyWhenDomainMissing() {
    let paths = Paths(root: makeTempDir(), wikiRaw: makeTempDir())
    let terms = PersonalDictionary.load(paths: paths, suiteName: "ot-tests-nonexistent-\(UUID().uuidString)")
    #expect(terms.isEmpty)
}

@Test func personalDictionaryReturnsEmptyOnCorruptSettingsFile() throws {
    let suiteName = "ot-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    // No wisperClone key set, so only the settings file matters here.

    let root = makeTempDir()
    let paths = Paths(root: root, wikiRaw: makeTempDir())
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("{ this is not valid json".utf8).write(to: paths.settingsFile)

    let terms = PersonalDictionary.load(paths: paths, suiteName: suiteName)
    #expect(terms.isEmpty)
}

// MARK: - FoundationModelsCorrector

// On CI / non-Apple-Silicon or macOS < 26, FoundationModels either doesn't compile in
// (guarded by `#if canImport`) or `SystemLanguageModel.default.availability != .available`.
// There is no injection seam for `SystemLanguageModel.default` itself, so the two guards
// below (`terms.isEmpty` and per-segment `minWordCount`) are what's independently
// verifiable without ever touching the real model — both are true no-ops on any machine,
// including this one where the model is `.available`.

@Test func correctorSkipsEverythingWhenNoTermsConfigured() async {
    let transcript = Transcript(
        session: SessionID(raw: "2026-08-16T14-03-00"),
        recordedAt: Date(),
        duration: 60,
        appName: "Zoom",
        calendarTitle: nil,
        segments: [
            TranscriptSegment(start: 0, end: 2, track: .mic, speaker: "Sebastian", text: "Amazon das Boat."),
        ]
    )
    let corrector = FoundationModelsCorrector(terms: [])
    let result = await corrector.correct(transcript)
    #expect(result == transcript)
}

@Test func correctorSkipsSegmentsBelowMinimumWordCount() async {
    let transcript = Transcript(
        session: SessionID(raw: "2026-08-16T14-03-00"),
        recordedAt: Date(),
        duration: 60,
        appName: "Zoom",
        calendarTitle: nil,
        segments: [
            TranscriptSegment(start: 0, end: 1, track: .mic, speaker: "Sebastian", text: "Okay klar."),
        ]
    )
    let corrector = FoundationModelsCorrector(terms: ["Dashboard"], minWordCount: 3)
    let result = await corrector.correct(transcript)
    #expect(result == transcript)
}

// MARK: - Fixtures

private func makeTempDir() -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    return dir
}

// The dictionary owns the spelling. A model that writes "Sellerboard" or "N8N" must not decide
// how a brand name looks in the wiki.

@Test func acceptedTermTakesTheDictionarySpelling() {
    let result = CorrectionGuard.apply(
        original: "Die Zahlen aus Sella Boat laufen nachts rein.",
        proposal: "Die Zahlen aus Sellerboard laufen nachts rein.",
        terms: ["sellerboard"]
    )
    #expect(result == "Die Zahlen aus sellerboard laufen nachts rein.")
}

@Test func dictionarySpellingSurvivesTrailingPunctuation() {
    let result = CorrectionGuard.apply(
        original: "Die Zahlen aus Sella Boat, seit gestern.",
        proposal: "Die Zahlen aus SellerBoard, seit gestern.",
        terms: ["sellerboard"]
    )
    #expect(result == "Die Zahlen aus sellerboard, seit gestern.")
}

// Observed live, three runs of the same audio: the model twice turned "Amazon das Boat" into
// "Amazon sellerboard". Being a dictionary term is not enough, the term also has to resemble
// what the recogniser produced.

private let confusableTerms = ["sellerboard", "Dashboard", "Bitwarden", "Mühlenbäcker", "ACOS"]

@Test func guardRejectsTheWrongTermFromTheDictionary() {
    let result = CorrectionGuard.apply(
        original: "Ich wollte den Stand beim Amazon das Boat durchgehen.",
        proposal: "Ich wollte den Stand beim Amazon sellerboard durchgehen.",
        terms: confusableTerms
    )
    #expect(result == "Ich wollte den Stand beim Amazon das Boat durchgehen.")
}

@Test func guardStillAcceptsTheTermThatActuallyFits() {
    let result = CorrectionGuard.apply(
        original: "Ich wollte den Stand beim Amazon das Boat durchgehen.",
        proposal: "Ich wollte den Stand beim Amazon Dashboard durchgehen.",
        terms: confusableTerms
    )
    #expect(result == "Ich wollte den Stand beim Amazon Dashboard durchgehen.")
}

@Test func guardAcceptsACloseMatchAndRejectsADistantOne() {
    #expect(CorrectionGuard.soundsLike("Sella Boat", term: "sellerboard", amongst: confusableTerms))
    #expect(CorrectionGuard.soundsLike("das Boat", term: "Dashboard", amongst: confusableTerms))
    #expect(!CorrectionGuard.soundsLike("das Boat", term: "sellerboard", amongst: confusableTerms))
    #expect(!CorrectionGuard.soundsLike("Lagerbestände", term: "Dashboard", amongst: confusableTerms))
}

@Test func guardRejectsATermSwappedForAnUnrelatedWord() {
    let result = CorrectionGuard.apply(
        original: "Die Lagerbestände werden nachts gezogen.",
        proposal: "Die ACOS werden nachts gezogen.",
        terms: confusableTerms
    )
    #expect(result == "Die Lagerbestände werden nachts gezogen.")
}

// The prefilter decides which segments are worth an LLM call at all. It must never drop a
// segment the guard would have accepted a correction for, and must drop the ordinary ones.

@Test func prefilterKeepsSegmentsWithAMangledTerm() {
    let terms = ["sellerboard", "Dashboard", "Mühlenbäcker"]
    #expect(CorrectionCandidates.mayContainTerm("Die Zahlen aus Sella Boat laufen nachts.", terms: terms))
    #expect(CorrectionCandidates.mayContainTerm("Stand beim Amazon das Boat durchgehen.", terms: terms))
    #expect(CorrectionCandidates.mayContainTerm("Der Kunde Muehlenbecker meldet sich.", terms: terms))
}

@Test func prefilterDropsOrdinarySentences() {
    let terms = ["sellerboard", "Dashboard", "Mühlenbäcker"]
    #expect(!CorrectionCandidates.mayContainTerm("Klar, sehr gerne, dann machen wir das so.", terms: terms))
    #expect(!CorrectionCandidates.mayContainTerm("Wir treffen uns morgen um zehn im Büro.", terms: terms))
}

@Test func prefilterDropsSegmentsWhereTheTermIsAlreadyCorrect() {
    // Nothing to repair, so no reason to let the model touch the sentence at all.
    #expect(!CorrectionCandidates.mayContainTerm(
        "Die Zahlen aus sellerboard laufen nachts.", terms: ["sellerboard", "Dashboard"]
    ))
}

@Test func prefilterWithoutTermsNeverAsksTheModel() {
    #expect(!CorrectionCandidates.mayContainTerm("Irgendein Satz.", terms: []))
}

// Repetition artifacts, taken verbatim from a real 32 minute meeting: overlapping transcription
// windows repeat a phrase before continuing.

@Test func repeatedPhraseFromAChunkBoundaryIsCollapsed() {
    #expect(
        RepetitionCleaner.clean("ich kann dir das auch mal kurz ich kann dir das auch mal kurz zeigen")
            == "ich kann dir das auch mal kurz zeigen"
    )
}

@Test func repetitionWithFillerBetweenIsCollapsed() {
    #expect(
        RepetitionCleaner.clean("Du brauchst halt dann wirklich so eine Du brauchst halt dann wirklich eine Kombination")
            == "Du brauchst halt dann wirklich eine Kombination"
    )
}

@Test func realSpeechIsLeftAlone() {
    // Someone genuinely saying a word twice, and an ordinary sentence, must survive untouched.
    #expect(RepetitionCleaner.clean("Das ist ist schon okay so") == "Das ist ist schon okay so")
    let sentence = "Die Zahlen laufen jetzt jede Nacht automatisch rein und wir sehen die Bestände."
    #expect(RepetitionCleaner.clean(sentence) == sentence)
}

// Aliases: the guard's distance rule blocks exactly the terms that matter most, so a declared
// mishearing is allowed to cross it. Both cases below come from the real transcript.

private let aliasSet = VocabularyAliases(entries: [
    "n8n": ["NANN"], "Claude": ["Clot", "Cloud"],
])

@Test func declaredMishearingIsAcceptedDespiteTheDistanceRule() {
    #expect(!CorrectionGuard.soundsLike("NANN", term: "n8n", amongst: ["n8n"]))
    let result = CorrectionGuard.apply(
        original: "die ganzen Workflows mit NANN gebaut",
        proposal: "die ganzen Workflows mit n8n gebaut",
        terms: ["n8n", "Claude"],
        aliases: aliasSet
    )
    #expect(result == "die ganzen Workflows mit n8n gebaut")
}

@Test func anUndeclaredWordStillHasToPassTheDistanceRule() {
    let result = CorrectionGuard.apply(
        original: "wir haben das gestern besprochen",
        proposal: "wir haben Claude gestern besprochen",
        terms: ["n8n", "Claude"],
        aliases: aliasSet
    )
    #expect(result == "wir haben das gestern besprochen")
}

@Test func aliasesAlsoGetSegmentsPastThePrefilter() {
    #expect(CorrectionCandidates.mayContainTerm(
        "der Workflow läuft in NANN und wird nachts getriggert", terms: ["n8n"], aliases: aliasSet
    ))
}
