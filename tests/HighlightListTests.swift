import Foundation
import Testing
@testable import FACore

private func h(_ id: String, page: Int, y: Double = 500, x: Double = 50, color: HighlightColor = .yellow, text: String = "text",
               note: String = "", created: Double = 0) -> Highlight {
    Highlight(id: id, page: page, rects: [Rect(x: x, y: y, w: 10, h: 12)], text: text, color: color, note: note, created: created)
}

private let sections = [
    Section(id: 0, title: "Cardio", start: 10, end: 19),
    Section(id: 1, title: "Endocrine", start: 20, end: 29),
]

private let sample = [
    h("a", page: 21, y: 300, color: .pink, text: "Graves disease", note: "#thyroid most common", created: 5),
    h("b", page: 21, y: 600, color: .yellow, text: "TSH low", created: 1),
    h("c", page: 12, color: .green, text: "Mitral stenosis", created: 3),
    h("d", page: 25, color: .pink, text: "Pheochromocytoma", created: 4),
    h("e", page: 12, y: 200, color: .blue, text: "Café au lait", created: 2),
]

@Test func filterByColorsPagesTagTextAndNotes() {
    #expect(HighlightList.filter(sample, HighlightFilter(colors: [.pink])).map(\.id) == ["a", "d"])
    #expect(HighlightList.filter(sample, HighlightFilter(colors: [.pink, .green])).map(\.id) == ["a", "c", "d"])
    #expect(HighlightList.filter(sample, HighlightFilter(pages: 20...22)).map(\.id) == ["a", "b"])
    #expect(HighlightList.filter(sample, HighlightFilter(tag: "Thyroid")).map(\.id) == ["a"])
    #expect(HighlightList.filter(sample, HighlightFilter(text: "graves COMMON")).map(\.id) == ["a"])
    #expect(HighlightList.filter(sample, HighlightFilter(text: "cafe")).map(\.id) == ["e"])
    #expect(HighlightList.filter(sample, HighlightFilter(withNotes: true)).map(\.id) == ["a"])
    #expect(HighlightList.filter(sample, HighlightFilter()).count == 5)
}

@Test func bookOrderIsPageThenTopToBottom() {
    #expect(HighlightList.sorted(sample, .book).map(\.id) == ["c", "e", "b", "a", "d"])
    #expect(HighlightList.sorted(sample, .newest).map(\.id) == ["a", "d", "c", "e", "b"])
    #expect(HighlightList.sorted(sample, .oldest).map(\.id) == ["b", "e", "c", "d", "a"])
}

@Test func groupBySectionInBookOrder() {
    let groups = HighlightList.groups(sample, by: .section, order: .book, sections: sections, pageLabel: { "p\($0)" })
    #expect(groups.map(\.title) == ["Cardio", "Endocrine"])
    #expect(groups.map { $0.highlights.map(\.id) } == [["c", "e"], ["b", "a", "d"]])
}

@Test func groupBySectionNewestFirstPutsTheNewestGroupFirst() {
    let groups = HighlightList.groups(sample, by: .section, order: .newest, sections: sections, pageLabel: { "p\($0)" })
    #expect(groups.map(\.title) == ["Endocrine", "Cardio"])
    #expect(groups[0].highlights.map(\.id) == ["a", "d", "b"])
}

@Test func groupByColorFollowsTheColorOrder() {
    let groups = HighlightList.groups(sample, by: .color, order: .book, sections: sections, pageLabel: { "p\($0)" })
    #expect(groups.map(\.title) == ["Yellow", "Green", "Pink", "Blue"])
    #expect(groups.map(\.color) == [.yellow, .green, .pink, .blue])
    #expect(groups[2].highlights.map(\.id) == ["a", "d"])
}

@Test func groupByPageUsesThePageLabel() {
    let groups = HighlightList.groups(sample, by: .page, order: .book, sections: sections, pageLabel: { "p. \($0 + 1)" })
    #expect(groups.map(\.title) == ["p. 13", "p. 22", "p. 26"])
}

@Test func noGroupingIsOneUntitledGroup() {
    let groups = HighlightList.groups(sample, by: .none, order: .book, sections: sections, pageLabel: { "\($0)" })
    #expect(groups.count == 1 && groups[0].title.isEmpty && groups[0].highlights.count == 5)
    #expect(HighlightList.groups([], by: .none, order: .book, sections: sections, pageLabel: { "\($0)" }).isEmpty)
}

@Test func highlightsBeforeTheFirstSectionGetTheirOwnGroup() {
    let groups = HighlightList.groups([h("z", page: 2)] + sample, by: .section, order: .book, sections: sections, pageLabel: { "\($0)" })
    #expect(groups.first?.title == "Before the first section")
}

@Test func countsPerColor() {
    #expect(HighlightList.counts(sample) == [.pink: 2, .yellow: 1, .green: 1, .blue: 1])
}

@Test func markdownListsGroupsHighlightsAndNotes() {
    let groups = HighlightList.groups(Array(sample.prefix(2)), by: .section, order: .book, sections: sections, pageLabel: { "p. \($0)" })
    let md = HighlightList.markdown(groups, pageLabel: { "p. \($0)" })
    #expect(md == """
    ## Endocrine

    - ==TSH low== (yellow) · p. 21
    - ==Graves disease== (pink) · p. 21
      > #thyroid most common

    """)
}
