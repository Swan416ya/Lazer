import 'package:flutter/foundation.dart';

/// Global shortcut layer → search page hand-off.
///
/// The search field lives inside the search page (it owns the query, the
/// debounce and the results), while `Ctrl+F` is handled by the shell-wide
/// shortcut layer. Bumping this counter asks the page to take keyboard focus
/// and bring itself to the top; the page listens and clears the request.
final ValueNotifier<int> searchFocusRequest = ValueNotifier<int>(0);

void requestSearchFocus() => searchFocusRequest.value++;
