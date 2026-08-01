## Install

Download the `.dmg`, open it, and drag iQualize to Applications. Universal build — Apple Silicon and Intel, macOS 14.2+.

iQualize is ad-hoc signed, not notarized. macOS quarantines web downloads, and for an unnotarized app that shows up as **"Apple could not verify 'iQualize' is free of malware that may harm your Mac or compromise your privacy"** on macOS Tahoe, or an "unidentified developer" block on older versions. Nothing is wrong with the download. Clear the flag once:

```bash
xattr -dr com.apple.quarantine /Applications/iQualize.app
```

Then open it normally, or use **System Settings → Privacy & Security → Security → Open Anyway** if you'd rather not use Terminal. For the `iqualize` command line tool: Settings (⌘,) → General → Install Command Line Tool.
