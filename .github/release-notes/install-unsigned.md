## Install

Download the `.dmg`, open it, and drag iQualize to Applications. Universal build: Apple Silicon and Intel, macOS 14.2+.

iQualize is signed with an ad-hoc signature, not a Developer ID certificate, and it is not notarized. macOS puts a quarantine flag on anything downloaded from the web, and for an app it cannot verify that shows up as a malware warning on first launch. Nothing is wrong with the download. Gatekeeper is reporting that the app has not been through Apple's notarization service, which requires a paid developer account.

The fastest fix is one command, which clears the flag so none of the warnings below appear:

```bash
xattr -dr com.apple.quarantine /Applications/iQualize.app
```

Then open it normally. If the `.dmg` itself will not mount, clear the flag on the download first: `xattr -c ~/Downloads/iQualize-*.dmg`.

#### Without Terminal

The GUI route works too, but it takes four screens and the first one looks like a dead end. Worth knowing what is coming.

**1. Open iQualize.** You get this. There is no "open anyway" here; that is expected. Click **Done**, not Move to Trash.

<img src="https://raw.githubusercontent.com/DariusCorvus/iqualize/main/assets/gatekeeper-1-blocked.webp" alt="macOS dialog: iQualize Not Opened. Apple could not verify iQualize is free of malware" width="340">

**2. Go to System Settings → Privacy & Security**, and scroll to **Security**. The blocked app now appears with an **Open Anyway** button. This row only shows up after step 1, which is why the order matters.

<img src="https://raw.githubusercontent.com/DariusCorvus/iqualize/main/assets/gatekeeper-2-open-anyway.webp" alt="System Settings Privacy and Security: iQualize was blocked to protect your Mac, with an Open Anyway button" width="620">

**3. Confirm.** macOS asks a second time, more sternly, and may ask for your password. Click **Open Anyway**.

<img src="https://raw.githubusercontent.com/DariusCorvus/iqualize/main/assets/gatekeeper-3-confirm.webp" alt="macOS dialog: Open iQualize? with Move to Trash, Open Anyway, and Done buttons" width="340">

**4. Allow audio capture.** This one is iQualize asking, not Gatekeeper. The EQ cannot work without it. It is the permission that lets the app see system audio at all.

<img src="https://raw.githubusercontent.com/DariusCorvus/iqualize/main/assets/gatekeeper-4-audio-permission.webp" alt="macOS dialog: iQualize would like access to record your system audio" width="340">

Older macOS versions expose the same **Open Anyway** option under **System Preferences → Security & Privacy → General**. Screenshots are from macOS Tahoe. Apple rewords these dialogs between releases.

If you ever see **"iQualize is damaged and can't be opened"** instead, that is a different problem: a genuinely broken signature rather than a missing one. That was [#115](https://github.com/DariusCorvus/iqualize/issues/115), fixed in 0.45.0. Report it if a current release does this.

For the `iqualize` command line tool: Settings (⌘,) → General → Install Command Line Tool.
