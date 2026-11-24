import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

import 'browser_host_blocker.dart';

export 'browser_host_blocker.dart';

/// Why this browser can't run the browser host (/play/), or null when it
/// can: a computer with WebGPU (Chrome, Edge, Safari, Firefox and Zen).
/// Phones are too slow.
BrowserHostBlocker? browserHostBlocker() {
  final navigator = web.window.navigator;
  final agent = navigator.userAgent;
  final phone = RegExp('Android|iPhone|iPad').hasMatch(agent) ||
      (navigator.platform == 'MacIntel' && navigator.maxTouchPoints > 1);
  if (phone) return BrowserHostBlocker.phone;
  if (!(navigator as JSObject).has('gpu')) return BrowserHostBlocker.browser;
  return null;
}

/// Whether this browser can run the browser host (/play/).
bool canHostInThisBrowser() => browserHostBlocker() == null;
