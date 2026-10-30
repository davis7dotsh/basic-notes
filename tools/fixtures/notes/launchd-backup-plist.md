# launchd agent for backup

`~/Library/LaunchAgents/com.example.nas-backup.plist`

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.example.nas-backup</string>
  <key>ProgramArguments</key>
  <array>
    <string>/Users/me/.local/bin/nas-backup</string>
  </array>
  <key>StartCalendarInterval</key>
  <dict>
    <key>Hour</key><integer>3</integer>
    <key>Minute</key><integer>15</integer>
  </dict>
  <key>StandardErrorPath</key>
  <string>/tmp/nas-backup.err</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>/opt/homebrew/bin:/usr/bin:/bin</string>
  </dict>
</dict>
</plist>
```

```bash
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.example.nas-backup.plist
launchctl kickstart -k gui/$(id -u)/com.example.nas-backup   # run now
launchctl print gui/$(id -u)/com.example.nas-backup | grep -i "last exit"
```
- PATH env is required or tailscale/rsync aren't found
- if mac is asleep at 3:15 it runs on wake
