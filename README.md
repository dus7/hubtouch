# HubTouch

Xcode 27 replaced Simulator.app with Device Hub, and Simulator.app's multitouch input didn't make the move.
HubTouch brings it back.

## Features

- **Two-finger touch** on iOS Simulators shown in Device Hub, the way Simulator.app did it:
  - Option: show two touch points
  - Option+click: two-finger tap
  - Option+drag: pinch / rotate
  - Option+Shift: move the pinch center
  - Option+Shift+drag: two-finger drag
- Finds the simulator screen and device in each Device Hub window automatically. Several windows at once are fine.
- A `hubtouch` command-line tool for scripted gestures:

  ```
  hubtouch pinch  --udid <UDID> --from 0.05 --to 0.3
  hubtouch rotate --udid <UDID> --degrees 90
  hubtouch twotap --udid <UDID>
  hubtouch twopan --udid <UDID> --dy -0.3
  ```

## Install

```
./build.sh
open build/HubTouch.app
```

HubTouch lives in the menu bar. Grant it **Accessibility** in System Settings > Privacy & Security.

## How it works

Touches are sent as `IndigoDigitizerEvent` messages to the simulator's `dtuhidd` HID service over XPC.
Simulator screens are located through Device Hub's accessibility tree.

## Caveats

- Relies on private CoreSimulator APIs, so any Xcode update may break it.
- Simulators only; physical devices are not supported. Two fingers at most.
- Not affiliated with or endorsed by Apple. Xcode and Device Hub are trademarks of Apple Inc.

## Disclaimer

Use HubTouch at your own risk. It is provided as is, with no guarantee that it works, or keeps working, reliably.

## License

Apache License 2.0. See [LICENSE](LICENSE).
