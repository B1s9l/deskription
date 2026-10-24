-- UI automation experiment only. It never changes Mission Control preferences.
-- Run from Script Editor after granting Accessibility. It creates a disposable TextEdit
-- document, and reports explicit verification failures instead of trusting delays/clicks.
tell application "System Events"
  if UI elements enabled is false then error "Accessibility permission is required"
end tell

tell application "TextEdit"
  activate
  make new document with properties {text:"Disposable Deskriptions Milestone 1 window"}
end tell
delay 1

tell application "System Events"
  key code 126 using control down -- Mission Control; public user-level keyboard action
  delay 2
  tell process "Dock"
    set addButtons to every button whose description contains "desktop"
    if (count of addButtons) is 0 then error "Could not locate Mission Control add-desktop control"
    click last item of addButtons
  end tell
  delay 2
  key code 124 using control down
  delay 2
  if not (exists window 1 of process "TextEdit") then error "Destination verification failed: disposable window is not AX-visible"
end tell
return "Created/switched candidate desktop; AX window visible. Visually confirm Space indicator before cleanup."
