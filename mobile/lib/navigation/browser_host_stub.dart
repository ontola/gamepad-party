import 'browser_host_blocker.dart';

export 'browser_host_blocker.dart';

/// Why this page can't be the TV screen itself: outside a browser, never.
BrowserHostBlocker? browserHostBlocker() => BrowserHostBlocker.app;

/// Whether this page can be the TV screen itself: never outside a browser.
bool canHostInThisBrowser() => false;
