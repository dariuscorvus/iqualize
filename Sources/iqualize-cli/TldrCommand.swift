import ArgumentParser
import Foundation

/// tldr-style cheat sheet: a short description plus a handful of concrete example
/// invocations per command, instead of ArgumentParser's full --help output. Colors are
/// only emitted when stdout is a real terminal, so piping/redirecting stays plain text.
struct Tldr: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "tldr", abstract: "Show quick usage examples for every command, tldr-style.")

    struct Entry {
        let name: String
        let description: String
        let examples: [(label: String, command: String)]
    }

    static let entries: [Entry] = [
        Entry(name: "status", description: "Show app version, capture/bypass/limiter state, active preset, gain, balance, spectrum overlays, and output device.", examples: [
            ("Show full status", "iqualize status"),
            ("Same thing — status is the default subcommand", "iqualize"),
        ]),
        Entry(name: "version", description: "Show the app version and build commit.", examples: [
            ("Show the running app's version", "iqualize version"),
        ]),
        Entry(name: "presets", description: "List all presets.", examples: [
            ("List all presets (active marked *, favorites ♥)", "iqualize presets"),
        ]),
        Entry(name: "preset", description: "Switch the active preset by name or ID.", examples: [
            ("Switch to a preset by name", "iqualize preset \"Bass Boost\""),
            ("Switch to a preset by ID", "iqualize preset 3F2504E0-4F89-11D3-9A0C-0305E82C3301"),
        ]),
        Entry(name: "bypass", description: "Get or set EQ bypass.", examples: [
            ("Show current bypass state", "iqualize bypass"),
            ("Bypass the EQ (passthrough)", "iqualize bypass on"),
            ("Turn the EQ back on", "iqualize bypass off"),
            ("Flip the current state", "iqualize bypass toggle"),
        ]),
        Entry(name: "gain input", description: "Get or set input gain, in dB.", examples: [
            ("Show current input gain", "iqualize gain input"),
            ("Set input gain to -5 dB", "iqualize gain input -5"),
            ("Set input gain to +3 dB", "iqualize gain input 3"),
        ]),
        Entry(name: "gain output", description: "Get or set output gain, in dB.", examples: [
            ("Show current output gain", "iqualize gain output"),
            ("Set output gain to +3 dB", "iqualize gain output 3"),
        ]),
        Entry(name: "gain link", description: "Get or set whether In/Out gain is shared across all presets.", examples: [
            ("Show whether gain is shared or per-preset", "iqualize gain link"),
            ("Share one gain setting across every preset", "iqualize gain link on"),
            ("Use a separate gain per preset", "iqualize gain link off"),
        ]),
        Entry(name: "balance", description: "Get or set stereo balance, from -1 (hard left) to 1 (hard right).", examples: [
            ("Show current balance", "iqualize balance"),
            ("Pan hard left", "iqualize balance -1"),
            ("Pan 50% right", "iqualize balance 0.5"),
            ("Center the balance", "iqualize balance 0"),
        ]),
        Entry(name: "limiter", description: "Get or set the peak limiter.", examples: [
            ("Show current limiter state", "iqualize limiter"),
            ("Enable the peak limiter", "iqualize limiter on"),
            ("Disable the peak limiter", "iqualize limiter off"),
        ]),
        Entry(name: "capture", description: "Get or set whether iQualize is capturing system audio.", examples: [
            ("Show whether capture is running", "iqualize capture"),
            ("Stop capturing (no processed audio)", "iqualize capture off"),
            ("Start capturing again", "iqualize capture on"),
        ]),
        Entry(name: "spectrum pre", description: "Get or set the Pre-EQ spectrum overlay.", examples: [
            ("Show current state", "iqualize spectrum pre"),
            ("Show the Pre-EQ overlay", "iqualize spectrum pre on"),
        ]),
        Entry(name: "spectrum post", description: "Get or set the Post-EQ spectrum overlay.", examples: [
            ("Show current state", "iqualize spectrum post"),
            ("Show the Post-EQ overlay", "iqualize spectrum post on"),
        ]),
        Entry(name: "band list", description: "List bands on the active preset, sorted by frequency.", examples: [
            ("List all bands", "iqualize band list"),
        ]),
        Entry(name: "band add", description: "Add a new band. Omitted values default to a sane starting point.", examples: [
            ("Add a band at the largest gap in the spectrum", "iqualize band add"),
            ("Add a 3 dB boost at 1 kHz", "iqualize band add --freq 1000 --gain 3"),
            ("Add a low shelf", "iqualize band add --freq 100 --gain 4 --filter lowShelf"),
        ]),
        Entry(name: "band set", description: "Change one or more values of an existing band. Addressed by --index (1-based, sorted by frequency) or --near (nearest frequency match) — mute doesn't touch gain, so a muted band's true gain is always shown.", examples: [
            ("Set the first band's gain", "iqualize band set --index 1 --gain -2"),
            ("Nudge the band nearest 1 kHz", "iqualize band set --near 1000 --freq 1200"),
        ]),
        Entry(name: "band delete", description: "Delete a band. A preset must keep at least one band.", examples: [
            ("Delete the third band", "iqualize band delete --index 3"),
        ]),
        Entry(name: "band move", description: "Swap a band's frequency with its next-lower or next-higher neighbor.", examples: [
            ("Move the second band right", "iqualize band move --index 2 right"),
        ]),
        Entry(name: "band mute", description: "Mute, unmute, or toggle a band. Non-destructive — the real gain is preserved and always shown by `band list`/`band set`.", examples: [
            ("Mute the first band", "iqualize band mute --index 1 on"),
            ("Toggle the band nearest 500 Hz", "iqualize band mute --near 500 toggle"),
        ]),
        Entry(name: "presets save", description: "Save the active preset, forking it first if it's built-in.", examples: [
            ("Save the active preset", "iqualize presets save"),
        ]),
        Entry(name: "presets reset", description: "Switch the active preset back to Flat.", examples: [
            ("Reset to Flat", "iqualize presets reset"),
        ]),
        Entry(name: "presets delete", description: "Delete a preset. Built-ins are hidden (recoverable via `restore`) rather than truly deleted; Flat can never be deleted.", examples: [
            ("Delete a custom preset", "iqualize presets delete \"Custom EQ 1\""),
            ("Hide a built-in", "iqualize presets delete Loudness"),
        ]),
        Entry(name: "presets new", description: "Create a new blank preset and make it active.", examples: [
            ("Create a preset with an auto-generated name", "iqualize presets new"),
            ("Create a preset with a specific name", "iqualize presets new \"My EQ\""),
        ]),
        Entry(name: "presets rename", description: "Rename a preset. Forks it first if it's built-in.", examples: [
            ("Rename a preset", "iqualize presets rename \"Custom EQ 1\" \"Studio Monitors\""),
        ]),
        Entry(name: "presets duplicate", description: "Duplicate a preset under a new name. Doesn't switch the active preset.", examples: [
            ("Duplicate with an auto-generated name", "iqualize presets duplicate \"Bass Boost\""),
            ("Duplicate with a specific name", "iqualize presets duplicate \"Bass Boost\" \"Bass Boost v2\""),
        ]),
        Entry(name: "presets favorite", description: "Get or set whether a preset is favorited.", examples: [
            ("Show whether a preset is favorited", "iqualize presets favorite \"Bass Boost\""),
            ("Favorite a preset", "iqualize presets favorite \"Bass Boost\" on"),
        ]),
        Entry(name: "presets pin", description: "Pin a preset to the current output device.", examples: [
            ("Pin a preset to whatever's plugged in now", "iqualize presets pin \"Studio Monitors\""),
        ]),
        Entry(name: "presets unpin", description: "Unpin whatever preset is pinned to the current output device.", examples: [
            ("Unpin the current device", "iqualize presets unpin"),
        ]),
        Entry(name: "presets hidden", description: "List built-in presets you've deleted (hidden) from the picker.", examples: [
            ("List hidden built-ins", "iqualize presets hidden"),
        ]),
        Entry(name: "presets restore", description: "Bring a hidden built-in preset back into the picker.", examples: [
            ("Restore a hidden built-in", "iqualize presets restore \"Loudness\""),
        ]),
        Entry(name: "presets import", description: "Import a preset file (iQualize .iqpreset, AutoEQ ParametricEQ.txt/GraphicEQ.txt, or OPRA eq_info.json).", examples: [
            ("Import a file", "iqualize presets import ~/Downloads/HD600\\ ParametricEQ.txt"),
            ("Import, replacing an existing preset of the same name", "iqualize presets import ~/Downloads/HD600.iqpreset --overwrite"),
        ]),
        Entry(name: "presets export", description: "Export a preset to a .iqpreset JSON file.", examples: [
            ("Export the active preset", "iqualize presets export --output ~/Desktop/MyEQ.iqpreset"),
            ("Export a specific preset by name", "iqualize presets export \"Bass Boost\" --output ~/Desktop/BassBoost.iqpreset"),
        ]),
        Entry(name: "presets opra search", description: "Search the OPRA community EQ catalog by vendor/product name.", examples: [
            ("Search for a headphone model", "iqualize presets opra search \"Sennheiser HD 600\""),
        ]),
        Entry(name: "presets opra import", description: "Import a curve from the OPRA catalog. --curve is only needed when a product has more than one community curve.", examples: [
            ("Import the only curve for a product", "iqualize presets opra import \"Sennheiser HD 600\""),
            ("Import a specific curve when there are several", "iqualize presets opra import \"Sennheiser HD 600\" --curve oratory1990"),
        ]),
    ]

    func run() {
        let useColor = isatty(fileno(stdout)) != 0
        func bold(_ s: String) -> String { useColor ? "\u{1B}[1m\(s)\u{1B}[0m" : s }
        func cyan(_ s: String) -> String { useColor ? "\u{1B}[36m\(s)\u{1B}[0m" : s }
        func dim(_ s: String) -> String { useColor ? "\u{1B}[2m\(s)\u{1B}[0m" : s }

        for (index, entry) in Self.entries.enumerated() {
            print(bold("iqualize \(entry.name)"))
            print("  \(entry.description)")
            print()
            for example in entry.examples {
                print(dim("  - \(example.label):"))
                print("      \(cyan(example.command))")
            }
            if index < Self.entries.count - 1 { print() }
        }
    }
}
