import Foundation
import Testing
@testable import FACore

private let line = "Graves disease is the most common cause of hyperthyroidism.\nToxic multinodular goiter: Wolff-Chaikoff effect."
private let text = PageText(line)

private func chars(_ s: String, after: String? = nil) -> IndexSet {
    let ns = line as NSString
    let start = after.map { ns.range(of: $0).upperBound } ?? 0
    let r = ns.range(of: s, range: NSRange(location: start, length: ns.length - start))
    precondition(r.location != NSNotFound, s)
    return IndexSet(integersIn: r.location..<(r.location + r.length))
}

private func string(_ set: IndexSet) -> String {
    let ns = line as NSString
    return text.runs(set).map { ns.substring(with: NSRange(location: $0.lowerBound, length: $0.count)) }.joined(separator: " | ")
}

private func existing(_ id: String, _ s: String, _ color: HighlightColor, note: String = "", created: Double = 100) -> PageHighlight {
    PageHighlight(Highlight(id: id, page: 0, rects: [], text: s, color: color, note: note, created: created), chars: chars(s))
}

private extension NSRange {
    var upperBound: Int { location + length }
}

// MARK: Word snapping

@Test func snapWidensPartialWordsToWholeWords() {
    #expect(string(text.snap(chars("aves dis"))) == "Graves disease")
    #expect(string(text.snap(chars("t"))) == "the")
    #expect(string(text.snap(chars("Chaik"))) == "Wolff-Chaikoff")
}

@Test func snapTrimsWhitespaceAtTheEnds() {
    #expect(string(text.snap(chars(" disease "))) == "disease")
}

@Test func snapKeepsWholeWordsAsTheyAre() {
    #expect(text.snap(chars("disease")) == chars("disease"))
}

@Test func snapStopsAtLineBreaks() {
    #expect(text.snap(chars("roidism.\nTox")) == chars("hyperthyroidism.\nToxic"))
}

@Test func runsJoinAcrossWhitespaceOnly() {
    var set = chars("Graves")
    set.formUnion(chars("disease"))
    #expect(text.runs(set).count == 1)
    set.formUnion(chars("common"))
    #expect(text.runs(set).count == 2)
}

// MARK: Plan

@Test func newHighlightWithNothingAroundIsOnePiece() {
    let plan = HighlightMerge.plan(chars("Graves disease"), color: .yellow, existing: [], text: text)
    #expect(plan.removed.isEmpty)
    #expect(plan.pieces.count == 1)
    #expect(string(plan.pieces[0].chars) == "Graves disease")
    #expect(plan.pieces[0].id == nil)
}

@Test func sameColorOverlapMergesIntoOneKeepingTheOldestID() {
    let a = existing("a", "Graves disease", .yellow, note: "first", created: 1)
    let b = existing("b", "most common", .yellow, note: "second", created: 2)
    let plan = HighlightMerge.plan(chars("disease is the most"), color: .yellow, existing: [b, a], text: text)
    #expect(Set(plan.removed.map(\.id)) == ["a", "b"])
    #expect(plan.pieces.count == 1)
    #expect(string(plan.pieces[0].chars) == "Graves disease is the most common")
    #expect(plan.pieces[0].id == "a")
    #expect(plan.pieces[0].created == 1)
    #expect(plan.pieces[0].note == "first\n\nsecond")
}

@Test func sameColorNextToAnExistingHighlightJoinsIt() {
    let a = existing("a", "Graves", .green)
    let plan = HighlightMerge.plan(chars("disease"), color: .green, existing: [a], text: text)
    #expect(plan.removed.map(\.id) == ["a"])
    #expect(string(plan.pieces[0].chars) == "Graves disease")
}

@Test func otherColorNextToAHighlightDoesNotTouchIt() {
    let a = existing("a", "Graves", .green)
    let plan = HighlightMerge.plan(chars("disease"), color: .pink, existing: [a], text: text)
    #expect(plan.removed.isEmpty)
    #expect(plan.pieces.count == 1)
}

@Test func highlightingInsideASameColorHighlightChangesNothing() {
    let a = existing("a", "Graves disease is the most common", .yellow)
    #expect(HighlightMerge.plan(chars("the most"), color: .yellow, existing: [a], text: text).isEmpty)
}

@Test func otherColorInsideAHighlightSplitsIt() {
    let a = existing("a", "Graves disease is the most common", .yellow, note: "note")
    let plan = HighlightMerge.plan(chars("is the"), color: .pink, existing: [a], text: text)
    #expect(plan.removed.map(\.id) == ["a"])
    let pink = plan.pieces.filter { $0.color == .pink }
    let yellow = plan.pieces.filter { $0.color == .yellow }
    #expect(pink.count == 1 && string(pink[0].chars) == "is the")
    #expect(yellow.map { string($0.chars) }.sorted() == ["Graves disease", "most common"])
    let kept = yellow.filter { $0.id == "a" }
    #expect(kept.count == 1 && kept[0].note == "note")
    #expect(yellow.filter { $0.id == nil }.allSatisfy { $0.note.isEmpty && $0.created == 100 })
}

@Test func otherColorCoveringAHighlightReplacesIt() {
    let a = existing("a", "disease", .yellow)
    let plan = HighlightMerge.plan(chars("Graves disease is"), color: .blue, existing: [a], text: text)
    #expect(plan.removed.map(\.id) == ["a"])
    #expect(plan.pieces.count == 1 && plan.pieces[0].color == .blue && plan.pieces[0].id == nil)
}

@Test func eraseTrimsAndSplitsWhateverItCovers() {
    let a = existing("a", "Graves disease is the most common", .yellow)
    let b = existing("b", "hyperthyroidism", .green)
    let c = existing("c", "Toxic multinodular", .pink)
    let plan = HighlightMerge.plan(chars("common cause of hyperthyroidism"), color: nil, existing: [a, b, c], text: text)
    #expect(Set(plan.removed.map(\.id)) == ["a", "b"])
    #expect(plan.pieces.count == 1)
    #expect(string(plan.pieces[0].chars) == "Graves disease is the most")
    #expect(plan.pieces[0].id == "a")
}

@Test func eraseOverNothingIsEmpty() {
    let a = existing("a", "Toxic multinodular", .pink)
    #expect(HighlightMerge.plan(chars("Graves"), color: nil, existing: [a], text: text).isEmpty)
}

@Test func leftoverPunctuationIsDropped() {
    let a = existing("a", "goiter:", .yellow)
    let plan = HighlightMerge.plan(chars("goiter"), color: .green, existing: [a], text: text)
    #expect(plan.pieces.count == 1 && plan.pieces[0].color == .green)
}

@Test func noteOnlyAnnotationsAreLeftAlone() {
    let n = existing("n", "Graves disease", .noteOnly)
    let plan = HighlightMerge.plan(chars("Graves"), color: .yellow, existing: [n], text: text)
    #expect(plan.removed.isEmpty)
}

// MARK: Tidy

@Test func tidyMergesStackedFragmentsOfOneColor() {
    let a = existing("a", "aves disease is th", .pink, created: 1)
    let b = existing("b", "e most com", .pink, created: 2)
    let c = existing("c", "Toxic", .green, created: 3)
    let plan = HighlightMerge.tidy([a, b, c], text: text)
    #expect(Set(plan.removed.map(\.id)) == ["a", "b"])
    #expect(plan.pieces.count == 1)
    #expect(string(plan.pieces[0].chars) == "Graves disease is the most common")
    #expect(plan.pieces[0].id == "a")
}

@Test func tidyLetsTheNewerColorWinWhereColorsOverlap() {
    let a = existing("a", "Graves disease is the", .yellow, created: 1)
    let b = existing("b", "disease", .blue, created: 2)
    let plan = HighlightMerge.tidy([b, a], text: text)
    let colors = plan.pieces.map { "\(string($0.chars))=\($0.color.name)" }.sorted()
    #expect(colors == ["Graves=yellow", "is the=yellow"])
    #expect(plan.removed.map(\.id) == ["a"])
}

@Test func tidyLeavesCleanHighlightsAlone() {
    let a = existing("a", "Graves disease", .yellow, created: 1)
    let b = existing("b", "hyperthyroidism", .green, created: 2)
    #expect(HighlightMerge.tidy([a, b], text: text).isEmpty)
}

@Test func tidyWidensASingleFragmentToWholeWords() {
    let page = PageText("II—intermediate zone")
    let a = Highlight(id: "a", page: 0, rects: [], text: "ntermediate", color: .green)
    let item = PageHighlight(a, chars: IndexSet(integersIn: 4..<15))
    let plan = HighlightMerge.tidy([item], text: page)
    #expect(plan.removed.map(\.id) == ["a"])
    #expect(plan.pieces.first?.chars == IndexSet(integersIn: 3..<15))
    #expect(plan.pieces.first?.id == "a")
}
