import ArgumentParser
import Foundation
import IQControlProtocol

func formatPresetLine(_ preset: CLIPresetSummary) -> String {
    let active = preset.isActive ? "*" : " "
    let favorite = preset.isFavorite ? "♥" : " "
    return "\(active) \(favorite) \(preset.name)"
}

extension Presets {
    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List all presets.")

        @Flag(help: "Show quick usage examples for this command.")
        var tldr = false

        func run() {
            if tldr { printTldr(matching: "presets"); return }
            let response = requireOK(sendOrExit(CLIRequest(command: CLICommand.listPresets)))
            guard let presets = response.presets else {
                printErr("Error: missing presets in response")
                return
            }
            for preset in presets { print(formatPresetLine(preset)) }
        }
    }

    struct Save: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Save the active preset in place, built-in or not.")

        @Flag(help: "Show quick usage examples for this command.")
        var tldr = false

        func run() {
            if tldr { printTldr(matching: "presets save"); return }
            let response = requireOK(sendOrExit(CLIRequest(command: CLICommand.saveActivePreset)))
            if let preset = response.presets?.first { print("Saved \"\(preset.name)\"") }
        }
    }

    struct Reset: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Switch the active preset back to Flat.")

        @Flag(help: "Show quick usage examples for this command.")
        var tldr = false

        func run() {
            if tldr { printTldr(matching: "presets reset"); return }
            let response = requireOK(sendOrExit(CLIRequest(command: CLICommand.resetActivePreset)))
            if let status = response.status { print("Preset: \(status.activePresetName)") }
        }
    }

    struct Delete: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Delete a preset. Built-ins are hidden (recoverable via `restore`) rather than truly deleted; Flat can never be deleted.")

        @Argument(help: "Preset name (case-insensitive) or UUID.")
        var name: String?
        @Flag(help: "Show quick usage examples for this command.")
        var tldr = false

        func validate() throws {
            guard tldr || name != nil else { throw ValidationError("Missing expected argument '<name>'") }
        }

        func run() {
            if tldr { printTldr(matching: "presets delete"); return }
            guard let name else { return }
            requireOK(sendOrExit(CLIRequest(command: CLICommand.deletePreset, stringArg: name)))
            print("Deleted \"\(name)\"")
        }
    }

    struct New: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Create a new blank preset and make it active.")

        @Argument(help: "Name for the new preset. Omit to auto-generate \"Custom EQ N\".")
        var name: String?
        @Flag(help: "Show quick usage examples for this command.")
        var tldr = false

        func run() {
            if tldr { printTldr(matching: "presets new"); return }
            let response = requireOK(sendOrExit(CLIRequest(command: CLICommand.newPreset, stringArg: name)))
            if let preset = response.presets?.first { print("Created \"\(preset.name)\"") }
        }
    }

    struct Rename: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Rename a preset, built-in or not.")

        @Argument(help: "Preset name (case-insensitive) or UUID to rename.")
        var name: String?
        @Argument(help: "New name.")
        var newName: String?
        @Flag(help: "Show quick usage examples for this command.")
        var tldr = false

        func validate() throws {
            guard tldr || (name != nil && newName != nil) else {
                throw ValidationError("Missing expected arguments '<name>' '<new-name>'")
            }
        }

        func run() {
            if tldr { printTldr(matching: "presets rename"); return }
            guard let name, let newName else { return }
            let response = requireOK(sendOrExit(CLIRequest(command: CLICommand.renamePreset, stringArg: name, stringArg2: newName)))
            if let preset = response.presets?.first { print("Renamed to \"\(preset.name)\"") }
        }
    }

    struct Duplicate: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Duplicate a preset under a new name. Doesn't switch the active preset.")

        @Argument(help: "Preset name (case-insensitive) or UUID to duplicate.")
        var source: String?
        @Argument(help: "Name for the copy. Omit to auto-generate \"<name> copy\".")
        var newName: String?
        @Flag(help: "Show quick usage examples for this command.")
        var tldr = false

        func validate() throws {
            guard tldr || source != nil else { throw ValidationError("Missing expected argument '<source>'") }
        }

        func run() {
            if tldr { printTldr(matching: "presets duplicate"); return }
            guard let source else { return }
            let response = requireOK(sendOrExit(CLIRequest(command: CLICommand.duplicatePreset, stringArg: source, stringArg2: newName)))
            if let preset = response.presets?.first { print("Duplicated to \"\(preset.name)\"") }
        }
    }

    struct Favorite: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Get or set whether a preset is favorited.")

        enum Action: String, ExpressibleByArgument, CaseIterable {
            case on, off, toggle
        }

        @Argument(help: "Preset name (case-insensitive) or UUID.")
        var name: String?
        @Argument(help: "on, off, or toggle. Omit to just print the current state.")
        var action: Action?
        // A separate flag, not another Action case: `name` is a required positional ahead
        // of `action` here (unlike bypass/limiter/capture, where the enum is the *only*
        // positional) — "tldr" typed positionally would bind to `name`, not `action`.
        @Flag(help: "Show quick usage examples for this command.")
        var tldr = false

        func validate() throws {
            guard tldr || name != nil else { throw ValidationError("Missing expected argument '<name>'") }
        }

        func run() {
            if tldr { printTldr(matching: "presets favorite"); return }
            guard let name else { return }
            let response: CLIResponse
            switch action {
            case nil:
                response = requireOK(sendOrExit(CLIRequest(command: CLICommand.listPresets)))
                let isFavorite = response.presets?.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.isFavorite
                print("Favorite: \(isFavorite == true ? "on" : "off")")
                return
            case .on:
                response = requireOK(sendOrExit(CLIRequest(command: CLICommand.setFavoritePreset, stringArg: name, boolArg: true)))
            case .off:
                response = requireOK(sendOrExit(CLIRequest(command: CLICommand.setFavoritePreset, stringArg: name, boolArg: false)))
            case .toggle:
                response = requireOK(sendOrExit(CLIRequest(command: CLICommand.toggleFavoritePreset, stringArg: name)))
            }
            let isFavorite = response.presets?.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.isFavorite
            print("Favorite: \(isFavorite == true ? "on" : "off")")
        }
    }

    struct Pin: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Pin a preset to the current output device.")

        @Argument(help: "Preset name (case-insensitive) or UUID.")
        var name: String?
        @Flag(help: "Show quick usage examples for this command.")
        var tldr = false

        func validate() throws {
            guard tldr || name != nil else { throw ValidationError("Missing expected argument '<name>'") }
        }

        func run() {
            if tldr { printTldr(matching: "presets pin"); return }
            guard let name else { return }
            requireOK(sendOrExit(CLIRequest(command: CLICommand.pinPreset, stringArg: name)))
            print("Pinned \"\(name)\" to the current output device.")
        }
    }

    struct Unpin: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Unpin whatever preset is pinned to the current output device.")

        @Flag(help: "Show quick usage examples for this command.")
        var tldr = false

        func run() {
            if tldr { printTldr(matching: "presets unpin"); return }
            requireOK(sendOrExit(CLIRequest(command: CLICommand.unpinPreset)))
            print("Unpinned.")
        }
    }

    struct Hidden: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List built-in presets you've deleted (hidden) from the picker.")

        @Flag(help: "Show quick usage examples for this command.")
        var tldr = false

        func run() {
            if tldr { printTldr(matching: "presets hidden"); return }
            let response = requireOK(sendOrExit(CLIRequest(command: CLICommand.listHiddenPresets)))
            guard let presets = response.presets else {
                printErr("Error: missing presets in response")
                return
            }
            if presets.isEmpty {
                print("No hidden built-in presets.")
            } else {
                for preset in presets { print(preset.name) }
            }
        }
    }

    struct Restore: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Bring a hidden built-in preset back into the picker.")

        @Argument(help: "Preset name (case-insensitive) or UUID.")
        var name: String?
        @Flag(help: "Show quick usage examples for this command.")
        var tldr = false

        func validate() throws {
            guard tldr || name != nil else { throw ValidationError("Missing expected argument '<name>'") }
        }

        func run() {
            if tldr { printTldr(matching: "presets restore"); return }
            guard let name else { return }
            requireOK(sendOrExit(CLIRequest(command: CLICommand.restoreBuiltInPreset, stringArg: name)))
            print("Restored \"\(name)\"")
        }
    }

    struct Import: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Import a preset file (iQualize .iqpreset, AutoEQ ParametricEQ.txt/GraphicEQ.txt, or OPRA eq_info.json).")

        @Argument(help: "Path to the file to import.")
        var path: String?
        @Flag(help: "Overwrite an existing preset with the same name.")
        var overwrite = false
        @Flag(help: "Show quick usage examples for this command.")
        var tldr = false

        func validate() throws {
            guard tldr || path != nil else { throw ValidationError("Missing expected argument '<path>'") }
        }

        func run() {
            if tldr { printTldr(matching: "presets import"); return }
            guard let path else { return }
            // Resolved to an absolute path here, in the CLI process — the app is a
            // long-running background process whose cwd has no relation to the terminal
            // this was invoked from, so a relative path would resolve against the wrong
            // directory if sent as-is.
            let absolutePath = URL(fileURLWithPath: path).standardizedFileURL.path
            let response = requireOK(sendOrExit(CLIRequest(command: CLICommand.importPresetFile, stringArg: absolutePath, boolArg: overwrite)))
            if let preset = response.presets?.first { print("Imported \"\(preset.name)\"") }
        }
    }

    struct Export: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Export a preset to a .iqpreset JSON file.")

        @Argument(help: "Preset name (case-insensitive) or UUID. Omit to export the active preset.")
        var name: String?
        @Option(name: .customLong("output"), help: "Output file path.")
        var output: String?
        @Flag(help: "Show quick usage examples for this command.")
        var tldr = false

        func validate() throws {
            guard tldr || output != nil else { throw ValidationError("Missing expected argument '--output <output>'") }
        }

        func run() {
            if tldr { printTldr(matching: "presets export"); return }
            guard let output else { return }
            let absolutePath = URL(fileURLWithPath: output).standardizedFileURL.path
            requireOK(sendOrExit(CLIRequest(command: CLICommand.exportPreset, stringArg: name, stringArg2: absolutePath)))
            print("Exported to \(absolutePath)")
        }
    }

    struct Opra: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "opra", abstract: "Search and import from the OPRA community EQ catalog.",
            subcommands: [Search.self, Import.self, Tldr.self])

        // OPRA's CC BY-SA 4.0 license requires attribution on any presentation of a browser
        // for the database — printed on every search/import, not just a "first run" flag.
        static let attribution = """
        OPRA is an open, community-maintained directory of product information and EQ \
        compensation curves for headphones. https://github.com/opra-project/OPRA

        """

        struct Search: ParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Search the OPRA catalog by vendor/product name.")

            @Argument(help: "Vendor or product name substring, e.g. \"Sennheiser HD 600\".")
            var query: String?
            @Flag(help: "Show quick usage examples for this command.")
            var tldr = false

            func validate() throws {
                guard tldr || query != nil else { throw ValidationError("Missing expected argument '<query>'") }
            }

            func run() {
                if tldr { printTldr(matching: "presets opra search"); return }
                guard let query else { return }
                print(Opra.attribution)
                let response = requireOK(sendOrExit(CLIRequest(command: CLICommand.searchOPRA, stringArg: query)))
                guard let products = response.opraProducts else {
                    printErr("Error: missing results in response")
                    return
                }
                if products.isEmpty {
                    print("No matches for '\(query)'.")
                } else {
                    for product in products {
                        print("\(product.vendorName) \(product.productName) — curves: \(product.curveAuthors.joined(separator: ", "))")
                    }
                }
            }
        }

        struct Import: ParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Import a curve from the OPRA catalog.")

            @Argument(help: "Vendor or product name substring — must match exactly one product.")
            var query: String?
            @Option(help: "Curve author, when a product has more than one community curve.")
            var curve: String?
            @Flag(help: "Overwrite an existing preset with the same name.")
            var overwrite = false
            @Flag(help: "Show quick usage examples for this command.")
            var tldr = false

            func validate() throws {
                guard tldr || query != nil else { throw ValidationError("Missing expected argument '<query>'") }
            }

            func run() {
                if tldr { printTldr(matching: "presets opra import"); return }
                guard let query else { return }
                print(Opra.attribution)
                let response = requireOK(sendOrExit(CLIRequest(command: CLICommand.importOPRA, stringArg: query, stringArg2: curve, boolArg: overwrite)))
                if let preset = response.presets?.first { print("Imported \"\(preset.name)\"") }
            }
        }

        struct Tldr: ParsableCommand {
            static let configuration = CommandConfiguration(commandName: "tldr", abstract: "Show quick usage examples for every presets opra command.")
            func run() { printTldr(matching: "presets opra") }
        }
    }
}
