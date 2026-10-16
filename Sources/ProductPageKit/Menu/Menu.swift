import ArgumentParser
import Foundation

/// What `productpage` opens with no arguments in a terminal: the commands to
/// walk with the arrow keys, each command's options asked for, and then the
/// command run as the command line it stands for. The line is printed first,
/// so it can be typed or scripted next time.
struct Menu {
    let project: Project
    let console: any Console
    let terminal: any MenuTerminal
    /// Runs a command line: `Root` parsing it, or a test standing in.
    let run: (_ arguments: [String]) async throws -> Void

    /// Returns when the person quits.
    func start() async {
        var groups: [any ParsableCommand.Type] = [Root.self]
        var cursors: [String: Int] = [:]
        while true {
            terminal.open()
            let arguments: [String]
            do {
                arguments = try command(in: &groups, cursors: &cursors)
            } catch {
                terminal.close()
                return
            }
            terminal.close()
            console.print("$ " + ([Root._commandName] + arguments).map(Self.quoted).joined(separator: " "))
            do {
                try await run(arguments)
            } catch {
                let message = Root.message(for: error)
                console.print(message.isEmpty ? "The command failed." : "Error: \(message)")
            }
            let answer = console.readLine(prompt: "\nReturn for the menu, q to quit: ")
            guard let answer, answer.trimmingCharacters(in: .whitespaces).lowercased() != "q" else { return }
        }
    }

    /// The arguments of the command chosen, walking into groups and out of
    /// them. `groups` and `cursors` keep the place, so the menu comes back to
    /// where the last command was chosen.
    private func command(in groups: inout [any ParsableCommand.Type],
                         cursors: inout [String: Int]) throws(MenuExit) -> [String] {
        while true {
            let group = groups[groups.count - 1]
            let path = groups.map { $0._commandName }
            let entries = Self.entries(of: group, in: project)
            let ask = Prompter(terminal: terminal, path: path)
            let question = groups.count == 1 ? "\(project.name): what do you want to do?" : group.configuration.abstract
            let index: Int
            do {
                index = try ask.choose(question, entries.map { Picker.Item($0._commandName, $0.configuration.abstract) },
                                       cursor: cursors[path.joined(separator: " ")] ?? 0)
            } catch .back {
                if groups.count > 1 { groups.removeLast() }
                continue
            }
            cursors[path.joined(separator: " ")] = index
            let entry = entries[index]
            guard let guided = entry as? any Guided.Type else {
                groups.append(entry)
                continue
            }
            ask.path = path + [entry._commandName]
            do {
                return Array(path.dropFirst()) + [entry._commandName] + (try guided.arguments(ask, project))
            } catch .back {
                continue
            }
        }
    }

    /// The group's commands and groups the project can use.
    static func entries(of group: any ParsableCommand.Type, in project: Project) -> [any ParsableCommand.Type] {
        group.configuration.subcommands.filter { isAvailable($0, in: project) }
    }

    private static func isAvailable(_ command: any ParsableCommand.Type, in project: Project) -> Bool {
        if let guided = command as? any Guided.Type { return guided.isAvailable(in: project) }
        return !entries(of: command, in: project).isEmpty
    }

    /// The argument as a shell would need it typed.
    static func quoted(_ argument: String) -> String {
        let plain = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.,:/=@+"))
        guard argument.isEmpty || argument.unicodeScalars.contains(where: { !plain.contains($0) }) else { return argument }
        return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
