import 'package:flutter/foundation.dart';

import 'desktop_now_playing.dart';

/// Hand-off from the shell's global shortcuts to the now-playing page.
///
/// The shell owns the keyboard, but which pane the page shows belongs to the
/// page, so shortcut handlers publish the intent here and the page consumes it.
/// `null` means "no request"; the page resets the value to `null` once read, so
/// pressing the same shortcut twice still works.
final ValueNotifier<DesktopNowPlayingPane?> nowPlayingPaneRequest =
    ValueNotifier<DesktopNowPlayingPane?>(null);
