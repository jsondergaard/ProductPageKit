import ArgumentParser
import Foundation
import Testing
@testable import ProductPageKit

/// Plays keys to the menu and keeps every screen it draws. Once the script
/// runs out, `respond` is asked what to press on the screen shown.
final class ScriptedTerminal: MenuTerminal {
    var keys: [Key]
    var respond: ([Line]) -> [Key] = { _ in [] }
    private(set) var screens: [[Line]] = []
    private(set) var opened = 0
    private(set) var closed = 0
    let rows: Int

    init(_ keys: [Key] = [], rows: Int = 30) {
        self.keys = keys
        self.rows = rows
    }

    func open() { opened += 1 }
    func close() { closed += 1 }
    func draw(_ lines: [Line]) { screens.append(lines) }

    func readKey() -> Key? {
        if keys.isEmpty { keys = respond(screens.last ?? []) }
        return keys.isEmpty ? nil : keys.removeFirst()
    }

    static func typed(_ text: String) -> [Key] { text.map { $0 == " " ? .space : .character($0) } }
}

@Suite struct KeyDecoderTests {
    func keys(_ bytes: [UInt8]) -> [Key] {
        var bytes = bytes[...]
        var keys: [Key] = []
        while let key = KeyDecoder.key({ _ in bytes.popFirst() }) { keys.append(key) }
        return keys
    }

    @Test func arrowsArriveInEitherCursorMode() {
        #expect(keys([0x1B, 0x5B, 0x41, 0x1B, 0x4F, 0x42, 0x1B, 0x5B, 0x43, 0x1B, 0x5B, 0x44]) == [.up, .down, .right, .left])
    }

    @Test func pageAndEndKeysCarryANumber() {
        #expect(keys(Array("\u{1B}[5~\u{1B}[6~\u{1B}[1~\u{1B}[4~\u{1B}[H\u{1B}[F".utf8)) == [.pageUp, .pageDown, .home, .end, .home, .end])
    }

    @Test func anEscapeWithNothingAfterItIsTheEscapeKey() {
        #expect(keys([0x1B]) == [.escape])
    }

    @Test func controlKeysAndTextAreToldApart() {
        #expect(keys([0x0D, 0x0A, 0x20, 0x7F, 0x03, 0x01]) == [.enter, .enter, .space, .backspace, .interrupt, .other])
        #expect(keys(Array("qø€😀".utf8)) == [.character("q"), .character("ø"), .character("€"), .character("😀")])
    }

    @Test func aFunctionKeyIsNoArrow() {
        #expect(keys(Array("\u{1B}[15~".utf8)) == [.other])
    }
}

@Suite struct PickerTests {
    let items = (1...6).map { Picker.Item("item\($0)") }

    @Test func theCursorStaysInTheListAndInView() {
        var picker = Picker(items, mode: .one)
        #expect(picker.handle(.up, height: 3) == nil)
        #expect(picker.cursor == 0)
        for _ in 1...4 { _ = picker.handle(.down, height: 3) }
        #expect(picker.cursor == 4)
        #expect(picker.top == 2)
        #expect(picker.lines(height: 3).map(\.text) == ["  item3   ", "  item4   ", "› item5   "])
        #expect(picker.position(height: 3) == "3–5 of 6")
        _ = picker.handle(.end, height: 3)
        _ = picker.handle(.down, height: 3)
        #expect(picker.cursor == 5)
        _ = picker.handle(.pageUp, height: 3)
        #expect(picker.cursor == 2)
        #expect(picker.top == 2)
        _ = picker.handle(.home, height: 3)
        #expect(picker.top == 0)
    }

    @Test func choosingOneAnswersWithTheCursor() {
        var picker = Picker(items, mode: .one, cursor: 2)
        #expect(picker.handle(.enter, height: 3) == .value([2]))
        #expect(picker.handle(.left, height: 3) == .back)
        #expect(picker.handle(.escape, height: 3) == .back)
        #expect(picker.handle(.character("q"), height: 3) == .quit)
        #expect(picker.handle(.interrupt, height: 3) == .quit)
    }

    @Test func tickingNeedsAtLeastOne() {
        var picker = Picker(items, mode: .many, ticked: Set(items.indices))
        _ = picker.handle(.character("a"), height: 3)
        #expect(picker.ticked.isEmpty)
        #expect(picker.handle(.enter, height: 3) == nil)
        #expect(picker.notice == "Tick at least one with space.")
        _ = picker.handle(.down, height: 3)
        #expect(picker.notice == nil)
        _ = picker.handle(.space, height: 3)
        _ = picker.handle(.space, height: 3)
        _ = picker.handle(.space, height: 3)
        #expect(picker.lines(height: 3).map(\.text) == ["[ ] item1   ", "[x] item2   ", "[ ] item3   "])
        _ = picker.handle(.character("a"), height: 3)
        #expect(picker.handle(.enter, height: 3) == .value(Array(items.indices)))
    }

    @Test func theCursorRowIsHighlightedAndDetailsDimmed() {
        let picker = Picker([Picker.Item("capture", "Build and capture."), Picker.Item("frame", "Frame.")], mode: .one)
        let lines = picker.lines(height: 5)
        #expect(lines[0].runs == [Line.Run(text: "› capture   ", style: .inverse), Line.Run(text: "Build and capture.", style: .dim)])
        #expect(lines[1].runs[0].style == .plain)
        #expect(picker.position(height: 5) == nil)
    }

    @Test func aTextFieldTakesALine() {
        var field = TextField()
        #expect(field.handle(.enter) == nil)
        #expect(field.notice == "Type an answer, or press Escape to go back.")
        for key in ScriptedTerminal.typed("1.9 x") { _ = field.handle(key) }
        _ = field.handle(.backspace)
        _ = field.handle(.backspace)
        #expect(field.handle(.character("q")) == nil)
        #expect(field.handle(.enter) == .value("1.9q"))
        #expect(field.handle(.escape) == .back)
        #expect(field.handle(.interrupt) == .quit)
    }

    @Test func theTerminalCutsALineAcrossItsRuns() {
        let line = Line(runs: [Line.Run(text: "abc", style: .bold), Line.Run(text: "defg", style: .dim)])
        #expect(TTY.render(line, width: 5) == "\u{1B}[1mabc\u{1B}[0m\u{1B}[2mde\u{1B}[0m")
        #expect(TTY.render(line, width: 2) == "\u{1B}[1mab\u{1B}[0m")
    }

    @Test func argumentsArePrintedAsAShellTakesThem() {
        #expect(Menu.quoted("--locales") == "--locales")
        #expect(Menu.quoted("en,da") == "en,da")
        #expect(Menu.quoted("/tmp/My Shots") == "'/tmp/My Shots'")
        #expect(Menu.quoted("it's") == "'it'\\''s'")
        #expect(Menu.quoted("") == "''")
    }
}

@Suite struct MenuTests {
    /// A project with everything the menu can offer.
    static func fixture() throws -> Fixture {
        let fixture = try Fixture(themes: [.frames, .videos])
        fixture.project.customPages = [CustomPage("pager", name: "Pager", platforms: [.iPhone], shots: ["home"])]
        fixture.project.experiments = [Experiment("pager", name: "Pager test", trafficProportion: 50, treatments: [
            Treatment("pager", name: "Pager", shots: ["home"]),
        ])]
        return fixture
    }

    static func leaves(of group: any ParsableCommand.Type, in project: Project?, path: [String] = []) -> [([String], any ParsableCommand.Type)] {
        let entries = project.map { Menu.entries(of: group, in: $0) } ?? group.configuration.subcommands
        return entries.flatMap { entry in
            let path = path + [entry._commandName]
            return entry.configuration.subcommands.isEmpty ? [(path, entry)] : leaves(of: entry, in: project, path: path)
        }
    }

    @Test func everyCommandCanBeRunFromTheMenu() {
        let commands = Self.leaves(of: Root.self, in: nil)
        #expect(commands.count == 19)
        for (path, command) in commands { #expect(command is any Guided.Type, "\(path) has no questions for the menu") }
    }

    /// Every question answered as it starts, a version and a directory typed:
    /// what the menu builds is a command line the parser takes, for the
    /// command chosen.
    @Test func everyCommandAnsweredWithItsDefaultsParsesAsItself() throws {
        let project = try Self.fixture().project
        let commands = Self.leaves(of: Root.self, in: project)
        #expect(commands.count == 19)
        for (path, command) in commands {
            let terminal = ScriptedTerminal()
            terminal.respond = { screen in
                screen.last?.text == "return confirm · esc back" ? ScriptedTerminal.typed("1.9") + [.enter] : [.enter]
            }
            let guided = try #require(command as? any Guided.Type)
            let arguments = try guided.arguments(Prompter(terminal: terminal, path: ["productpage"] + path), project)
            let parsed = try Root.parseAsRoot(path + arguments)
            #expect(ObjectIdentifier(type(of: parsed)) == ObjectIdentifier(command), "\(path + arguments)")
        }
    }

    @Test func commandsTheProjectCannotRunAreLeftOut() throws {
        var project = try Fixture().project
        project.products = nil
        #expect(Menu.entries(of: Root.self, in: project).map { $0._commandName }
            == ["metadata", "release", "screenshots", "review", "export", "cache", "doctor"])
        #expect(Menu.entries(of: ScreenshotsCommand.self, in: project).map { $0._commandName } == ["capture"])
        let full = try Self.fixture().project
        #expect(Menu.entries(of: Root.self, in: full).count == Root.configuration.subcommands.count)
    }

    @Test func everythingTickedNamesNothingAndUntickingNamesTheRest() throws {
        let project = try Self.fixture().project
        let capture = ScriptedTerminal([.enter, .down, .space, .enter, .enter])
        #expect(try ScreenshotsCommand.Capture.arguments(Prompter(terminal: capture, path: []), project) == ["--locales", "en"])
        let all = ScriptedTerminal([.enter, .enter, .enter])
        #expect(try ScreenshotsCommand.Capture.arguments(Prompter(terminal: all, path: []), project) == [])
        #expect(all.screens[0][2].text == "Which platforms?")
        #expect(all.screens[1][4].text.hasPrefix("[x] en"))
    }

    @Test func someShotsAreTickedFromThePlatformsChosen() throws {
        let project = try Self.fixture().project
        let terminal = ScriptedTerminal([.down, .space, .enter, .enter, .down, .enter, .down, .space, .enter])
        let arguments = try ScreenshotsCommand.Capture.arguments(Prompter(terminal: terminal, path: []), project)
        #expect(arguments == ["--platforms", "ios", "--shots", "list"])
        #expect(terminal.screens.last?.dropFirst(4).prefix(2).map(\.text) == ["[ ] home   ", "[x] list   "])
    }

    @Test func aWriteCanBeADryRunOrApplied() throws {
        let project = try Self.fixture().project
        #expect(try ProductsCommand.Push.arguments(Prompter(terminal: ScriptedTerminal([.down, .enter]), path: []), project) == ["--dry-run"])
        #expect(try ProductsCommand.Push.arguments(Prompter(terminal: ScriptedTerminal([.end, .enter]), path: []), project) == ["--yes"])
    }

    @Test func goingBackFromAQuestionLeavesTheCommand() throws {
        let project = try Self.fixture().project
        #expect(throws: MenuExit.back) {
            try ScreenshotsCommand.Capture.arguments(Prompter(terminal: ScriptedTerminal([.escape]), path: ["productpage", "x"]), project)
        }
        #expect(throws: MenuExit.quit) {
            try ScreenshotsCommand.Capture.arguments(Prompter(terminal: ScriptedTerminal([]), path: []), project)
        }
    }

    /// Into metadata, check run, then back in the same group on the same
    /// command, out to the top and quit.
    @Test func theMenuRunsTheCommandChosenAndComesBackToIt() async throws {
        let fixture = try Self.fixture()
        let console = RecordingConsole(answers: [""])
        let terminal = ScriptedTerminal([.enter, .enter, .escape, .down, .character("q")])
        let runs = Runs()
        await Menu(project: fixture.project, console: console, terminal: terminal) { runs.add($0) }.start()

        #expect(runs.all == [["metadata", "check"]])
        #expect(console.output.contains("$ productpage metadata check"))
        #expect(terminal.opened == 2)
        #expect(terminal.closed == 2)
        let reopened = terminal.screens[2]
        #expect(reopened[0].text == "productpage › metadata")
        #expect(reopened.first { $0.runs.first?.style == .inverse }?.text.hasPrefix("› check") == true)
        let top = terminal.screens[3]
        #expect(top[2].text == "Example: what do you want to do?")
        #expect(top.first { $0.runs.first?.style == .inverse }?.text.hasPrefix("› metadata") == true)
        #expect(terminal.screens[4].first { $0.runs.first?.style == .inverse }?.text.hasPrefix("› release") == true)
    }

    @Test func aFailedCommandSaysWhyAndTheMenuCarriesOn() async throws {
        let fixture = try Self.fixture()
        let console = RecordingConsole(answers: [""])
        let terminal = ScriptedTerminal([.end, .enter])
        await Menu(project: fixture.project, console: console, terminal: terminal) { _ in
            throw Stopped(description: "Nothing changed.")
        }.start()
        #expect(console.output.contains("$ productpage doctor\nError: Nothing changed."))
        #expect(terminal.opened == 2)
    }

    @Test func aRealCommandRunsAgainstTheSession() async throws {
        let fixture = try Fixture()
        fixture.console = RecordingConsole(answers: ["q"])
        let session = fixture.session
        let terminal = ScriptedTerminal([.enter, .enter])
        await Session.$current.withValue(session) {
            await Menu(project: session.project, console: session.console, terminal: terminal, run: Root.execute).start()
        }
        #expect(fixture.console.output.contains("$ productpage metadata check\n\(session.project.metadata.catalog) is ready"))
    }

    @Test func withoutATerminalTheRootPrintsItsHelp() async throws {
        let fixture = try Self.fixture()
        fixture.console = RecordingConsole(interactive: false)
        await #expect(throws: CleanExit.self) {
            try await Session.$current.withValue(fixture.session) { try await Root().run() }
        }
    }
}

/// The command lines a menu ran.
final class Runs: @unchecked Sendable {
    private let lock = NSLock()
    private var runs: [[String]] = []

    func add(_ arguments: [String]) { lock.withLock { runs.append(arguments) } }
    var all: [[String]] { lock.withLock { runs } }
}
