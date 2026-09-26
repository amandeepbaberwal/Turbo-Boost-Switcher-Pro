# Helper build

No Xcode project required for testing. Direct clang build (Intel + arm64):

```bash
cd /Users/amandeep/tbd/turbomenu
mkdir -p build
xcrun clang -O2 -fobjc-arc \
  -I Shared \
  -framework Foundation -framework IOKit \
  Helper/main.m Helper/TurboBoostHelper.m \
  -o build/tbhelper
./build/tbhelper --help 2>&1 | head -3  # it will run as a daemon; Ctrl-C to stop
```

For Xcode/SMJobBless later: create a Command Line Tool (Foundation) target,
add these three files, set team `CL2J5F345D`, add `Helper-Info.plist` as its
Info.plist with `-sectcreate __TEXT __info_plist` embedding, then fill
`SMAuthorizedClients` via `scripts/make-requirements.sh`.

App side (`HelperManager.m`) compiles inside the forked app target with
`ServiceManagement.framework` linked:

```bash
# syntax check only (AppKit/Cocoa comes from the app target):
xcrun clang -fsyntax-only -fobjc-arc -I Shared -F /System/Library/Frameworks \
  App/HelperManager.m
```
