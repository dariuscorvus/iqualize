## Install

Download the `.dmg`, open it, and drag iQualize to Applications. Universal build — Apple Silicon and Intel, macOS 14.2+.

iQualize is ad-hoc signed, not notarized. macOS quarantines web downloads, and for an unnotarized app that shows up as **"iQualize is damaged and can't be opened"**. It isn't. Clear the flag once:

```bash
xattr -dr com.apple.quarantine /Applications/iQualize.app
```

Then open it normally. For the `iqualize` command line tool: Settings (⌘,) → General → Install Command Line Tool.
