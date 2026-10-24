# Deskriptions tester guide

## Install

1. Unzip the macOS artifact, move `Deskriptions.app` to `/Applications`, and open it once.
2. Run `install-release-bridge.sh` from the extracted folder. It registers the bridge embedded inside that app; rerunning it safely replaces the same user-level registration.
3. Open `chrome://extensions`, `brave://extensions`, or `edge://extensions`, enable Developer mode, choose **Load unpacked**, and select the supplied `Chrome Extension` folder.
4. Reload the extension and click its toolbar button. Open the browser's version page and copy the complete **Profile Path** into Settings → Extensions.
5. Grant Screen & System Audio Recording only if testing live previews. Use Setup & Status to run the functional capture check; quit and reopen only when macOS still reports that the first grant requires it. The global shortcuts may require Input Monitoring; menu commands remain available.

Default shortcuts are Control-Option-P for a live preview, Control-Option-S for Save Desktop, and Control-Option-L for Load Desktop. They can be changed or cleared in Settings.

## Suggested disposable tests

- Save only selected `example.com` tabs while another disposable tab stays open; then load the saved Desktop.
- Repeat a load as a new load, then interrupt another load and choose Retry. Report whether groups or tabs duplicate.
- Pin a TextEdit or disposable browser-window preview, move between Spaces/fullscreen, minimize/restore the source, replace the preview, and dismiss it.
- Temporarily disable the unpacked extension and confirm the recovery message. Re-enable it afterward.
- Confirm loading begins directly in the current macOS desktop without a Space-creation or fallback prompt. Deskriptions must never remove a Space.

Do not use irreplaceable tabs or unsaved documents during beta testing. Deskriptions reconstructs URLs and window grouping; it does not preserve forms, arbitrary application memory, or unsaved page state.

## Reporting a bug

Include the app version, macOS version, browser version, exact steps, expected result, actual result, and whether Retry was used. Choose Settings → Diagnostics → Export Diagnostics… and review the JSON before attaching it. By design it contains counts, versions, and operation-status totals only—no URLs, titles, Desktop names, profile identities, credentials, or saved Desktop contents.

## Uninstall and recovery

Run `uninstall.sh`, remove the unpacked extension in Chrome, and move the app to the Trash. This preserves saved Desktops and settings. To remove those separately, first make a backup if wanted, then delete `~/Library/Application Support/Deskriptions/` and the `org.deskriptions.app` preferences entry. Removing a saved Desktop in the app never deletes source documents or browser content.

If the extension cannot connect after moving the app, rerun `install-release-bridge.sh` after the move and reload the extension. If a load was interrupted, open the same saved Desktop and choose Retry; choose Start new load only when another copy is intended.
